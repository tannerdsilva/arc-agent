import Foundation
import Logging
import ServiceLifecycle

/// A background service that runs scheduled cron jobs.
///
/// The ``CronScheduler`` polls the cron store for active jobs and runs them
/// when their schedule fires. Each job runs as an isolated Task.
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
/// - **Second Law**: ``CronScheduler`` is a ``Service`` in the lifecycle tree.
public actor CronScheduler: Service {

    private let store: any CronStore
    private let pollInterval: UInt64
    /// The wall-clock zone cron schedules in. Daemon-wide (``CronConfig``):
    /// a job's "9am" means 9am *here*, regardless of which profile wrote it.
    private let timeZone: TimeZone
    /// Executes a due job. When non-nil, the job's output becomes
    /// `lastOutput` (capped at 4 KB); when nil (tests/standalone), the
    /// scheduler bookkeeps without running anything. The daemon injects a
    /// runner that turns the job into a one-shot agent session.
    private let jobRunner: (@Sendable (CronJob) async throws -> String)?
    private let logger = Logger(label: "com.arc-agent.cron-scheduler")

    public init(
        store: any CronStore,
        pollIntervalSeconds: UInt64 = 30,
        timeZone: TimeZone = .current,
        jobRunner: (@Sendable (CronJob) async throws -> String)? = nil
    ) {
        self.store = store
        self.pollInterval = pollIntervalSeconds * 1_000_000_000
        self.timeZone = timeZone
        self.jobRunner = jobRunner
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
                    // Log and continue on transient errors
                }

                try await Task.sleep(nanoseconds: interval)
            }
        }

        logger.info("Cron scheduler stopped.")
    }

    /// One poll pass: run every active job whose next run has arrived.
    /// Extracted from ``run()`` so tests can drive a single pass.
    func runDueJobs(now: Date = Date()) async throws {
        let activeJobs = try await store.listActive()

        for var job in activeJobs {
            guard let nextRun = job.nextRunAt ?? CronSchedule.next(job.schedule, after: now, timeZone: timeZone) else {
                // First run — compute and store.
                job.nextRunAt = CronSchedule.next(job.schedule, after: now, timeZone: timeZone)
                // A schedule that still yields no next run is a dead job:
                // this guard is the only place that notices, so say so —
                // every pass, the UI shows it a bare "—".
                if job.nextRunAt == nil {
                    logger.warning("Cron job '\(job.name)' (schedule: '\(job.schedule)') has no computable next run — it will never fire; fix or delete it")
                }
                try await store.save(job)
                continue
            }

            if now >= nextRun {
                logger.info("Running job: \(job.name)")
                do {
                    if let runner = jobRunner {
                        let output = try await runner(job)
                        job.lastOutput = String(output.prefix(4000))
                    } else {
                        // Bookkeeping-only mode (tests / no runner).
                        job.lastOutput = "Executed at \(now)"
                    }
                    job.lastRunAt = now
                    job.runCount += 1
                    job.nextRunAt = CronSchedule.next(job.schedule, after: now, timeZone: timeZone)
                    try await store.save(job)
                } catch {
                    job.lastRunAt = now
                    job.runCount += 1
                    job.lastOutput = "Error: \(error)"
                    job.nextRunAt = CronSchedule.next(job.schedule, after: now, timeZone: timeZone)
                    try await store.save(job)
                    logger.error("Cron job \(job.name) failed: \(error)")
                }
            }
        }
    }
}

/// Parse a schedule expression and compute the next run date.
///
/// **Deleted** — the engine now lives in ``CronSchedule`` (ArcAgentCore/Cron/
/// CronSchedule.swift): one parser for full 5-field cron (ranges, lists,
/// steps, day-of-week names, the dom/dow OR rule), human intervals, and ISO
/// one-shots, with explicit timezone handling. The old `computeNextRun`
/// here was wrong in four documented ways and duplicated by the web UI's
/// `CronNext`; both are gone.
