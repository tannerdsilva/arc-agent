import Foundation
import Logging
import ServiceLifecycle

/// A background service that runs scheduled cron jobs.
///
/// The ``CronScheduler`` polls the cron store for active jobs and runs them
/// when their schedule fires. Due jobs fire CONCURRENTLY within a pass (one
/// child task each, joined before the next poll), and every run is bounded
/// by ``CronScheduler/runTimeout`` — a hung runner can delay a pass but can
/// never wedge the loop permanently.
///
/// ## Schedule Format
///
/// Supports:
/// - Human-readable intervals: "30m", "every 2h", "1d"
/// - Cron expressions: "0 9 * * *" (daily at 9am)
/// - ISO timestamps: "2026-06-01T09:00:00Z" (one-shot)
///
/// ## Law of the Land
///
/// - **First Law**: due jobs run in a `TaskGroup`; the run timeout is a
///   structured race (no locks, no detached tasks).
/// - **Second Law**: ``CronScheduler`` is a ``Service`` in the lifecycle tree.
public actor CronScheduler: Service {

    private let store: any CronStore
    private let pollInterval: UInt64
    /// The wall-clock zone cron schedules in. Daemon-wide (``CronConfig``):
    /// a job's "9am" means 9am *here*, regardless of which profile wrote it.
    private let timeZone: TimeZone
    /// Per-attempt history. Nil = no history is written (tests). In file
    /// mode a record file is written per run; in tessera mode the backend
    /// no-ops because the single `save(job)` below IS the record.
    private let history: (any CronRunHistory)?
    /// Executes a due job. When non-nil, the job's output becomes
    /// `lastOutput` (capped at 4 KB); when nil (tests/standalone), the
    /// scheduler bookkeeps without running anything. The daemon injects a
    /// runner that turns the job into a one-shot agent session.
    private let jobRunner: (@Sendable (CronJob) async throws -> CronRunResult)?
    /// Maximum wall-clock time one job run may take. A hung runner (an LLM
    /// connection with no read timeout, a wedged transport) must never be
    /// able to freeze the poll loop: the run is cancelled and recorded as
    /// an error instead. Nil = unlimited (reserved for tests that drive
    /// `runDueJobs(now:)` directly and want no timer in the race).
    private let runTimeout: TimeInterval?
    private let logger = Logger(label: "com.arc-agent.cron-scheduler")
    /// One-announcement-per-lifecycle guards (in-memory on purpose: a restart
    /// may re-announce once, which is honest — the durable state is the job).
    private var completedAnnounced: Set<String> = []
    private var deadAnnounced: Set<String> = []

    public init(
        store: any CronStore,
        pollIntervalSeconds: UInt64 = 30,
        timeZone: TimeZone = .current,
        history: (any CronRunHistory)? = nil,
        jobRunner: (@Sendable (CronJob) async throws -> CronRunResult)? = nil,
        runTimeout: TimeInterval? = 900
    ) {
        self.store = store
        self.pollInterval = pollIntervalSeconds * 1_000_000_000
        self.timeZone = timeZone
        self.history = history
        self.jobRunner = jobRunner
        self.runTimeout = runTimeout
    }

    public func run() async throws {
        logger.info("Cron scheduler started (poll interval: \(pollInterval / 1_000_000_000)s)")

        // the loop exits on cancellation; `runUntilShutdown` converts the
        // group's graceful shutdown into that cancellation, so SIGTERM stops
        // the poll promptly instead of waiting out the grace period.
        let interval = pollInterval
        try await runUntilShutdown { [self] in
            while !Task.isCancelled {
                do {
                    try await self.runDueJobs()
                } catch {
                    // Transient errors must be visible, not swallowed — a
                    // silently failing poll loop looks exactly like "no
                    // jobs due" from the outside.
                    logger.error("Cron poll failed: \(error)")
                }

                try await Task.sleep(nanoseconds: interval)
            }
        }

        logger.info("Cron scheduler stopped.")
    }

    /// One poll pass: run every active job whose next run has arrived.
    /// Extracted from ``run()`` so tests can drive a single pass.
    ///
    /// Two phases: (1) select — the per-job skip/self-heal/first-compute
    /// logic, which touches actor-isolated announcement state; (2) fire —
    /// every due job in a `TaskGroup` child, joined before returning. A
    /// child that outlives the pass (an LLM call slower than the poll
    /// interval) no longer delays the jobs behind it, and the per-run
    /// timeout guarantees the group ALWAYS terminates.
    func runDueJobs(now: Date = Date()) async throws {
        let activeJobs = try await store.listActive()

        var due: [CronJob] = []
        for var job in activeJobs {
            // Paused jobs never fire. `isActive` is false AND `pausedAt`
            // set — the transition is visible on the job, no per-poll
            // spam beyond one debug line.
            if job.pausedAt != nil {
                logger.debug("Cron job '\(job.name)' is paused (\(job.pausedReason ?? "no reason")) — skipping")
                continue
            }
            // A MANUAL-ONLY job (no schedule) with no armed fire date is
            // legitimate, not dead: it runs when the user says so (Run
            // now arms `nextRunAt`). Skip silently — the dead-job warning
            // below is for jobs whose schedule is broken, not absent.
            if job.schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, job.nextRunAt == nil {
                continue
            }
            // SELF-HEAL: a one-shot that already fired must never sit armed.
            // The pre-fix re-arm wrote jobs whose `nextRunAt` still points at
            // their own (future) ISO instant — clear it so the job settles
            // into Completed. A Run-now RETRY arms at ~now (past or due by
            // the time this pass runs), so only a FUTURE pointer is stale.
            if !CronSchedule.isRecurring(job.schedule), job.lastRunAt != nil,
               let armed = job.nextRunAt, armed > now {
                job.nextRunAt = nil
                var healed = job
                if let fresh = try? await store.get(id: job.id) {
                    healed = fresh
                    healed.nextRunAt = nil
                }
                try? await store.save(healed)
                logger.notice("Cron one-shot '\(job.name)' already fired — cleared its stale future arm")
                continue
            }
            var nextRun = job.nextRunAt ?? CronSchedule.next(job.schedule, after: now, timeZone: timeZone)
            if job.nextRunAt == nil, let computed = nextRun {
                // First compute — store once, so the UI shows a real next
                // run instead of "—" until the firing pass.
                job.nextRunAt = computed
                try await store.save(job)
            }
            guard let nextRun else {
                // No computable next run. Two very different situations
                // share this shape, and only one of them is a problem:
                //
                //   • the job HAS fired and its schedule now yields nil —
                //     a spent one-shot (or an exhausted cadence). That is
                //     completion, not breakage: the UI already renders
                //     `nextRunAt == nil` as Completed. Announce once at
                //     info, never warn, and never save — the state does
                //     not change pass to pass (the old code warned and
                //     saved on EVERY poll for a done job).
                //
                //   • the job has NEVER fired and the schedule yields nil
                //     — genuinely dead (unparseable/garbage). Warn once,
                //     so a broken job stays loud without spamming every
                //     pass.
                if job.lastStartedAt != nil {
                    if completedAnnounced.insert(job.id).inserted {
                        logger.info("Cron job '\(job.name)' has fired and its schedule yields no further runs — completed")
                    }
                } else if deadAnnounced.insert(job.id).inserted {
                    logger.warning("Cron job '\(job.name)' (schedule: '\(job.schedule)') has no computable next run — it will never fire; fix or delete it")
                }
                continue
            }
            // Re-armed (an edit landed a fresh schedule): the announcement
            // sets must not swallow a later exhaustion's notice.
            completedAnnounced.remove(job.id)
            deadAnnounced.remove(job.id)

            if now >= nextRun {
                due.append(job)
            }
        }

        guard !due.isEmpty else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for job in due {
                group.addTask { [self] in
                    await self.fire(job, now: now)
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Firing

    /// Run one due job to completion: gate → runner (bounded by the run
    /// timeout) → bookkeeping merge → exactly one store save → history.
    /// All errors are absorbed and stamped onto the job — a firing is
    /// never allowed to escape into the task group (one bad job must not
    /// cancel its siblings).
    private func fire(_ job: CronJob, now: Date) async {
        logger.info("Running job: \(job.name)")
        // One run per job at a time: a manual Run-now in the web UI
        // shares this process, so the gate (not just this actor's
        // state) decides. A skipped firing is not lost — the next
        // pass re-evaluates the schedule.
        guard await CronRunGate.shared.tryAcquire(job.id) else {
            logger.debug("Cron job '\(job.name)' is already running (manual Run-now?) — skipping this firing")
            return
        }
        var job = job
        // Single-save rule: stamp every last* field, write file-mode
        // history, then EXACTLY ONE store.save — that save is both
        // bookkeeping and, in tessera mode, the durable run record.
        // Never record() + a separate save (two kind-3005 publishes).
        let startedAt = now
        job.lastStartedAt = startedAt
        // Hand the runner a copy that carries the reset signal, but
        // clear it on the persisted job: the signal is consumed by
        // THIS firing (crash between = flag still true = retried).
        var runJob = job
        job.needsSessionReset = false
        do {
            if let runner = jobRunner {
                let result = try await boundedRunner(runner, run: runJob)
                job.lastOutput = String(result.output.prefix(cronOutputCap))
                job.lastDeliveryError = result.deliveryError
                // A runner-reported failure (script nonzero exit, turn
                // engine out of retries) stamps error WITHOUT losing the
                // output text — the run row still shows what happened.
                if let runError = result.error {
                    job.lastStatus = "error"
                    job.lastError = runError
                    logger.error("Cron job \(job.name) failed: \(runError)")
                } else {
                    job.lastStatus = "ok"
                    job.lastError = nil
                }
            } else {
                // Bookkeeping-only mode (tests / no runner).
                job.lastOutput = "Executed at \(now)"
                job.lastDeliveryError = nil
            }
            job.lastStatus = "ok"
            job.lastError = nil
        } catch {
            if isTimeout(error) {
                logger.error("Cron job \(job.name) exceeded its \(self.runTimeout.map { Int($0) } ?? 0)s run timeout — cancelled")
            } else {
                logger.error("Cron job \(job.name) failed: \(error)")
            }
            job.lastStatus = "error"
            job.lastError = String(describing: error)
        }
        await finish(job: job, runJob: runJob, startedAt: startedAt, now: now)
        await CronRunGate.shared.release(job.id)
    }

    /// The bookkeeping half of a firing — split from ``fire`` so the
    /// timeout error path shares it. Re-reads the store copy and applies
    /// ONLY run bookkeeping onto the fresh copy (the lost-update guard).
    private func finish(job: CronJob, runJob: CronJob, startedAt: Date, now: Date) async {
        var job = job
        job.lastRunAt = now
        job.lastFinishedAt = Date()
        job.runCount += 1
        // Reset-every-N (§7.2): the counter rides the per-run save
        // (survives restarts). When the bucket crosses the
        // threshold the counter zeroes and the NEXT firing starts
        // in a fresh session — never mid-firing.
        if job.resetEveryRuns != nil {
            job.runsSinceReset = (job.runsSinceReset ?? 0) + 1
            if let every = job.resetEveryRuns,
               let since = job.runsSinceReset, since >= every {
                job.runsSinceReset = 0
                job.needsSessionReset = true
                logger.notice("Cron job '\(job.name)' hit its reset-every-\(every) bucket — next firing starts a fresh session")
            }
        }
        // Run budget: arm on first run if unset, then count down —
        // SUCCESS only. A failed run consumes nothing: the job
        // (even a one-shot) stays retryable until a run succeeds.
        // At zero the job self-retires — a final "no more runs"
        // state visible on the job, never a fake record.
        if let budget = job.runBudget, job.lastStatus == "ok" {
            if job.runsRemaining == nil { job.runsRemaining = budget }
            job.runsRemaining = max(0, (job.runsRemaining ?? budget) - 1)
            if job.runsRemaining == 0 {
                job.isActive = false
                logger.notice("Cron job '\(job.name)' completed its run budget (\(budget) runs) — deactivated")
            }
        }
        // Re-arm ONLY recurring schedules. A one-shot instant (or a
        // manual job's empty schedule) has fired its only moment —
        // clear the pointer so the job settles into Completed/Idle
        // instead of re-arming to the same future instant forever.
        job.nextRunAt = CronSchedule.isRecurring(job.schedule)
            ? CronSchedule.next(job.schedule, after: now, timeZone: timeZone)
            : nil
        // Lost-update guard: the run took wall-clock time, so an
        // edit (or another writer) may have landed in the store
        // meanwhile. Re-read and apply ONLY run bookkeeping onto the
        // fresh copy — saving the pass-start snapshot would silently
        // revert the edit (the "edited prompt didn't take" bug).
        var persist = job
        var deleted = false
        if let fresh = try? await store.get(id: job.id) {
            var merged = fresh
            merged.lastStartedAt = job.lastStartedAt
            merged.lastFinishedAt = job.lastFinishedAt
            merged.lastStatus = job.lastStatus
            merged.lastOutput = job.lastOutput
            merged.lastError = job.lastError
            merged.lastDeliveryError = job.lastDeliveryError
            merged.lastRunAt = job.lastRunAt
            merged.runCount = max(job.runCount, fresh.runCount) + (job.runCount > fresh.runCount ? 0 : 1)
            // The reset flag and bucket are the scheduler's own
            // transition state (armed/consumed within this firing) —
            // copy verbatim. ORing the fresh copy would resurrect a
            // flag this firing just consumed.
            merged.runsSinceReset = job.runsSinceReset
            merged.needsSessionReset = job.needsSessionReset
            merged.isActive = job.isActive && fresh.isActive
            merged.runsRemaining = job.runsRemaining
            // Next fire: re-arm only RECURRING schedules. A one-shot
            // instant (or a manual job's empty schedule) has fired
            // its only moment — clear the pointer so the job settles
            // into Completed/Idle instead of re-arming to the same
            // future instant forever.
            merged.nextRunAt = CronSchedule.isRecurring(merged.schedule)
                ? CronSchedule.next(merged.schedule, after: now, timeZone: timeZone)
                : nil
            persist = merged
        } else {
            // The job vanished from the store mid-run (the user
            // deleted it). Saving the stale copy would resurrect it —
            // skip the save and the history record entirely.
            deleted = true
            logger.info("Cron job '\(job.name)' was deleted mid-run — dropping the post-run save")
        }
        if deleted { return }
        if let history {
            let run = CronRunRecord(
                jobID: job.id,
                startedAt: startedAt,
                finishedAt: persist.lastFinishedAt,
                status: persist.lastStatus,
                output: persist.lastOutput ?? "",
                error: persist.lastError
            )
            try? await history.record(run, jobID: job.id)
        }
        try? await store.save(persist)
    }

    /// Bound one runner invocation by the run timeout: a structured race
    /// between the runner and a timer. Whichever finishes first wins; the
    /// loser is cancelled. This is what turns "an LLM call hung forever"
    /// from a permanent scheduler wedge into an ordinary error stamp.
    private func boundedRunner(
        _ runner: @escaping @Sendable (CronJob) async throws -> CronRunResult,
        run job: CronJob
    ) async throws -> CronRunResult {
        guard let timeout = runTimeout else { return try await runner(job) }
        return try await withThrowingTaskGroup(of: CronRunResult.self) { group in
            group.addTask { try await runner(job) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CronSchedulerError.runTimedOut(after: timeout)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func isTimeout(_ error: Error) -> Bool {
        error is CronSchedulerError
    }
}

/// Errors the scheduler itself raises around a firing.
enum CronSchedulerError: Error {
    /// The run exceeded ``CronScheduler/runTimeout`` and was cancelled.
    case runTimedOut(after: TimeInterval)
}

/// Parse a schedule expression and compute the next run date.
///
/// **Deleted** — the engine now lives in ``CronSchedule`` (ArcAgentCore/Cron/
/// CronSchedule.swift): one parser for full 5-field cron (ranges, lists,
/// steps, day-of-week names, the dom/dow OR rule), human intervals, and ISO
/// one-shots, with explicit timezone handling. The old `computeNextRun`
/// here was wrong in four documented ways and duplicated by the web UI's
/// `CronNext`; both are gone.
