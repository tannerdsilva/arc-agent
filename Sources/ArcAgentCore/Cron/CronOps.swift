import Foundation

// MARK: - Cron management operations
//
// The *shared* mutation layer behind `arc cron …` (CLI) and, later, the
// `cronjob` agent tool. Pure async helpers over a ``CronStore`` — no
// argument parsing, no printing — so both surfaces get identical
// validation and bookkeeping. Deliberately in ArcAgentCore (not the CLI
// target) so the tool and the web UI reuse it.

/// A cron management operation failed (unknown id, invalid schedule).
public struct CronOpsError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum CronOps {

    // MARK: - Create

    /// Create a job. The schedule is validated with the unified engine
    /// (``CronSchedule``) BEFORE anything is persisted — a garbage
    /// schedule never becomes a silently-never-firing job.
    public static func create(
        store: any CronStore,
        name: String,
        schedule: String,
        prompt: String,
        deliver: String? = nil,
        script: String? = nil,
        resetEveryRuns: Int? = nil,
        contextFrom: [String]? = nil,
        runBudget: Int? = nil
    ) async throws -> CronJob {
        // An EMPTY schedule is legal — a manual-only job (runs when the
        // user says so). Anything non-empty must parse.
        let trimmed = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard CronSchedule.isValid(schedule) else {
                throw CronOpsError("invalid schedule '\(schedule)' — use 5-field cron, '30m'/'2h'/'1d', an ISO timestamp, or leave it empty for a manual job")
            }
        }
        // A ONE-SHOT cannot also be recurring: one fire total means the
        // schedule is either a single instant or nothing at all.
        if runBudget == 1, CronSchedule.isRecurring(schedule) {
            throw CronOpsError("a one-shot (run budget 1) cannot have a recurring schedule — use a single ISO timestamp or no schedule")
        }
        try vetScript(script)
        var job = CronJob(name: name, schedule: schedule, prompt: prompt)
        job.nextRunAt = trimmed.isEmpty ? nil : CronSchedule.next(schedule, after: Date())
        job.deliver = normalizedDeliver(deliver)
        job.script = script
        job.resetEveryRuns = resetEveryRuns
        job.contextFrom = (contextFrom?.isEmpty ?? true) ? nil : contextFrom
        job.runBudget = runBudget
        if runBudget != nil { job.runsRemaining = runBudget }
        try await store.save(job)
        return job
    }

    // MARK: - Edit

    /// Edit a job's schedule (and optionally prompt/name). A new schedule
    /// is revalidated and `nextRunAt` is recomputed — an edit must never
    /// leave a stale fire date from the old cadence.
    public static func edit(
        store: any CronStore,
        id: String,
        name: String? = nil,
        schedule: String? = nil,
        prompt: String? = nil,
        deliver: String?? = nil,
        script: String?? = nil,
        resetEveryRuns: Int?? = nil,
        contextFrom: [String]?? = nil,
        runBudget: Int?? = nil
    ) async throws -> CronJob {
        guard var job = try await store.get(id: id) else {
            throw CronOpsError("no such job: \(id)")
        }
        if let schedule {
            let trimmed = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard CronSchedule.isValid(schedule) else {
                    throw CronOpsError("invalid schedule '\(schedule)' — job left untouched")
                }
            }
            job.schedule = schedule
            job.nextRunAt = trimmed.isEmpty ? nil : CronSchedule.next(schedule, after: Date())
        }
        if let runBudget {  // outer = presence (don't touch vs set)
            // A one-shot cannot be recurring — check against the schedule
            // this edit leaves on the job (nil clears the budget).
            if runBudget == 1, CronSchedule.isRecurring(job.schedule) {
                throw CronOpsError("a one-shot (run budget 1) cannot have a recurring schedule — job left untouched")
            }
            job.runBudget = runBudget
            // Re-arm the countdown when a budget appears/changes; a nil
            // budget clears it entirely.
            if let b = runBudget { job.runsRemaining = b } else { job.runsRemaining = nil }
        }
        // One-shot invariants against the job's OWN schedule (covers edits
        // that change the schedule while a budget is already set).
        if job.runBudget == 1, CronSchedule.isRecurring(job.schedule) {
            throw CronOpsError("a one-shot (run budget 1) cannot have a recurring schedule — job left untouched")
        }
        if let name { job.name = name }
        if let prompt { job.prompt = prompt }
        if let deliver { job.deliver = normalizedDeliver(deliver) }
        if let script {
            let value: String? = script  // String?? outer holds presence
            try vetScript(value)
            job.script = (value?.isEmpty ?? true) ? nil : value
        }
        if let resetEveryRuns { job.resetEveryRuns = resetEveryRuns }
        if let contextFrom {  // outer = presence (don't touch vs set)
            // Unknown ids are tolerated, not rejected: jobs may be created
            // in dependency order, and injection skips absent upstreams.
            if let ids = contextFrom {  // inner = the list (nil clears)
                job.contextFrom = ids.isEmpty ? nil : ids
            } else {
                job.contextFrom = nil
            }
        }
        try await store.save(job)
        return job
    }

    /// `"none"` → nil; a `platform:chatID` string stays (grammar validated
    /// at delivery time by ``CronDeliveryTarget`` — an invalid target is a
    /// persisted `lastDeliveryError`, not a rejected job).
    private static func normalizedDeliver(_ deliver: String?) -> String? {
        guard let deliver, deliver != "none", !deliver.isEmpty else { return nil }
        return deliver
    }

    /// Public vetting for the tool's create path (CronOps keeps its own).
    public static func vetScriptPublic(_ script: String) throws {
        guard !script.isEmpty else { return }
        if let hit = HardlineBlocker.detect(script) {
            throw CronOpsError("hardline: \(hit) — script rejected at creation; approval cannot launder it")
        }
    }

    /// Creation-time vetting: a script is security-screened ONCE, when it
    /// is stored — not per-run. A hardline script never becomes a stored
    /// job, so no approval prompt can launder it later. Soft/execution-flag
    /// findings are recorded but not blocking (the script runs unattended
    /// by design; the human chose the line).
    private static func vetScript(_ script: String?) throws {
        guard let script, !script.isEmpty else { return }
        if let hit = HardlineBlocker.detect(script) {
            throw CronOpsError("hardline: \(hit) — script rejected at creation; approval cannot launder it")
        }
    }

    // MARK: - Pause / Resume

    /// Pause: `isActive = false` + `pausedAt` stamp. The scheduler skips
    /// inactive jobs, so the stale `nextRunAt` simply never fires.
    /// ONE-SHOTS cannot be paused (they have one fire — pause adds no
    /// semantics); reschedule or delete instead.
    public static func pause(store: any CronStore, id: String, reason: String? = nil) async throws -> CronJob {
        guard var job = try await store.get(id: id) else {
            throw CronOpsError("no such job: \(id)")
        }
        guard !job.isOneShot else {
            throw CronOpsError("a one-shot job cannot be paused — reschedule or delete it instead")
        }
        job.isActive = false
        job.pausedAt = Date()
        job.pausedReason = reason
        try await store.save(job)
        return job
    }

    /// Resume: `isActive = true`, `pausedAt` cleared, and `nextRunAt`
    /// recomputed from NOW. A pause longer than the cadence must not
    /// trigger a catch-up burst the moment the job comes back.
    public static func resume(store: any CronStore, id: String) async throws -> CronJob {
        guard var job = try await store.get(id: id) else {
            throw CronOpsError("no such job: \(id)")
        }
        job.isActive = true
        job.pausedAt = nil
        job.nextRunAt = CronSchedule.next(job.schedule, after: Date())
        try await store.save(job)
        return job
    }

    // MARK: - Run now

    /// Arm a job to fire on the scheduler's next pass: `nextRunAt = now`.
    /// No inline execution — the daemon's session host owns running, and
    /// duplicating it here would bypass every session guard.
    ///
    /// A SPENT one-shot refuses (completed means completed — the UI
    /// grays the button, the op enforces it). Setting `nextRunAt = now`
    /// also consumes any pending scheduled firing (one pending firing
    /// at most). A budget that hasn't fired yet is untouched — a failed
    /// one-shot is retryable here.
    public static func runNow(store: any CronStore, id: String) async throws -> CronJob {
        guard var job = try await store.get(id: id) else {
            throw CronOpsError("no such job: \(id)")
        }
        guard !job.isBudgetSpent || job.lastStatus == "error" else {
            throw CronOpsError("job '\(job.name)' has completed its run budget and cannot run again")
        }
        job.nextRunAt = Date()
        try await store.save(job)
        return job
    }

    // MARK: - Remove

    /// Remove a job AND its run history. The job JSON goes via the store;
    /// the `<store dir>/history/<id>/` record directory goes with it —
    /// an orphaned history tree for a deleted job is just rot.
    public static func remove(store: any CronStore, id: String) async throws {
        // Missing id → error, like pause/resume/run: a silent no-op remove
        // would let a caller believe a job is gone when it never existed.
        guard try await store.get(id: id) != nil else {
            throw CronOpsError("no such job: \(id)")
        }
        try await store.delete(id: id)
        if let fileStore = store as? FileCronStore {
            let historyDir = fileStore.homeDirectory
                .appendingPathComponent("history", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.removeItem(at: historyDir)
        }
    }

    // MARK: - Due-now (the `list` indicator that replaces Hermes's `tick`)

    /// Whether the scheduler would fire this job on its next pass.
    /// Inactive jobs are never due — pause must hold even for stale slots.
    public static func isDue(_ job: CronJob, now: Date = Date()) -> Bool {
        guard job.isActive, let next = job.nextRunAt else { return false }
        return next <= now
    }
}
