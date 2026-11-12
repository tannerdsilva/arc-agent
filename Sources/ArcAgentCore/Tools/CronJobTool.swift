import ArcToolKit
import Foundation

// MARK: - cronjob (reference `tools/cron_tools.py`)

/// Tool: `cronjob` — create/edit/list/pause/resume/run/remove scheduled
/// jobs and read their run history.
///
/// ## Scope
///
/// Services are constructor parameters: a surface built without a cron
/// store simply does not carry this tool (the messaging precedent — absent
/// services mean absent tools, not tools that fail at call time). The
/// store and history it closes over are the same ones the daemon's
/// scheduler and the CLI's `arc cron` act through, so all three surfaces
/// observe one job set with no cache to go stale.
///
/// Jobs created here are stamped with the captured ``ToolContext``'s
/// profile — the tool cannot forget to, because the context is a value
/// captured at build time and the handler is the only write path.
public enum CronJobTool {

    /// Build the tool for one caller.
    ///
    /// - Parameters:
    ///   - context: the calling identity. Its profile is stamped on
    ///     created jobs; its grant is unused today (job management is not
    ///     a document write) but captured for symmetry with the other
    ///     profile-scoped tools.
    ///   - store: the cron store this surface's jobs live in — the daemon
    ///     passes its `RuntimeCronStore`-resolved backend so the agent and
    ///     the scheduler can never disagree about medium.
    ///   - history: the run-history backend for the `history` action.
    ///     Nil keeps the tool but the action explains that no history is
    ///     wired (never crashes).
    public static func entry(
        context: ToolContext,
        store: any CronStore,
        history: (any CronRunHistory)? = nil
    ) -> ToolEntry {
        ToolEntry(
            name: "cronjob",
            toolset: "scheduling",
            description: "Manage your scheduled jobs (cron). Actions: create, edit, list, "
                + "pause, resume, run, remove, history.\n\n"
                + "create needs name and either a prompt (LLM job) or a script (shell job — "
                + "the line runs instead of the agent); schedule is optional — omit it (or pass \"\") "
                + "for a schedule-less manual job that never auto-fires (Idle in the web UI, "
                + "triggered via the run action). Schedule syntax: 5-field cron "
                + "('0 9 * * *', with ranges/lists/steps like '*/15' and 'mon-fri'), human "
                + "intervals ('30m', '2h', 'daily'), or an ISO one-shot "
                + "('2026-06-01T09:00:00Z'). Times are the daemon's wall-clock zone.\n\n"
                + "run arms a job for the NEXT scheduler pass (≤30s) — it does not execute "
                + "inline. pause/resume keep history; remove deletes the job AND its run "
                + "history. history shows the newest attempts with status and output.\n\n"
                + "Jobs you create are stamped with your profile. run_budget makes a one-shot: "
                + "set 1 and the schedule must be a single ISO instant (or the job fires only "
                + "when run manually). A failed one-shot stays retryable; a succeeded one is "
                + "completed and cannot run, pause, or re-arm again.",
            schema: .object(
                description: "Scheduled job parameters",
                properties: [
                    "action": .enum(
                        description: "The management action.",
                        values: ["create", "edit", "list", "pause", "resume", "run", "remove", "history"]
                    ),
                    "id": .string(description: "Job ID (all actions except create/list)."),
                    "name": .string(description: "Job name (create, or edit to rename)."),
                    "schedule": .string(
                        description: "5-field cron, human interval ('30m', 'daily'), or ISO one-shot "
                            + "(create, or edit to recadence). Optional: omit or pass \"\" for a "
                            + "schedule-less manual job — it never auto-fires and lives in the "
                            + "web UI's Idle group; trigger it with the run action. "
                            + "Validated when present."
                    ),
                    "prompt": .string(description: "Prompt fired at each run (create, or edit). "
                        + "Ignored when a script is set."),
                    "script": .string(description: "Shell line run INSTEAD of the LLM each firing "
                        + "(create, or edit; pass \"\" to clear and revert to prompt mode). "
                        + "Stdout is the run's output; empty stdout + exit 0 is silent; "
                        + "non-zero/timeout alerts. Screened for catastrophic commands at "
                        + "creation — a rejected script is never stored."),
                    "limit": .string(description: "Max records for history (default 10)."),
                    "deliver": .string(description: "RESERVED for Phase 5 (platform delivery)."),
                    "run_budget": .integer(
                        description: "Total allowed successful runs; 1 = one-shot (then the "
                            + "schedule must be a single ISO instant). Omit for unlimited."
                    ),
                ],
                required: ["action"]
            ),
            handler: { args in
                let action = (args["action"] as? String) ?? ""
                // House style: every failure is a legible "Error: …" string.
                // CronOps and the store throw (CronOpsError, missing jobs);
                // the agent sees the message, not a thrown tool error.
                do {
                    return try await dispatch(action, args, context: context, store: store, history: history)
                } catch {
                    return "Error: \(error)"
                }
            },
            emoji: "⏰"
        )
    }

    private static func dispatch(
        _ action: String,
        _ args: [String: Any],
        context: ToolContext,
        store: any CronStore,
        history: (any CronRunHistory)?
    ) async throws -> String {
        switch action {
                case "create":
                    return try await performCreate(args, context: context, store: store)
                case "edit":
                    return try await performEdit(args, store: store)
                case "list":
                    return try await performList(store: store)
                case "pause":
                    return try await performSimple(args, store: store) { try await performPause($0, store: store) }
                case "resume":
                    return try await performSimple(args, store: store) { try await performResume($0, store: store) }
                case "run":
                    return try await performSimple(args, store: store) { try await performRun($0, store: store) }
                case "remove":
                    return try await performSimple(args, store: store) { jobID in
                        try await CronOps.remove(store: store, id: jobID)
                        return "Removed \(jobID) (job + history)."
                    }
                case "history":
                    return try await performHistory(args, store: store, history: history)
                default:
                    return "Error: unknown action '\(action)'. Valid actions: create, edit, list, pause, resume, run, remove, history"
                }
    }

    // MARK: - Actions

    private static func performCreate(
        _ args: [String: Any],
        context: ToolContext,
        store: any CronStore
    ) async throws -> String {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return "Error: 'name' is required for create."
        }
        let script = (args["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = ""
        if let script, !script.isEmpty {
            try CronOps.vetScriptPublic(script)
        } else {
            guard let p = args["prompt"] as? String, !p.isEmpty else {
                return "Error: 'prompt' (or 'script') is required for create."
            }
            prompt = p
        }
        // Schedule is optional: an omitted/empty schedule creates a
        // schedule-less manual job (never auto-fires, Idle in the web UI).
        let schedule = (args["schedule"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !schedule.isEmpty {
            guard CronSchedule.isValid(schedule) else {
                return "Error: invalid schedule '\(schedule)' — use 5-field cron, '30m'/'2h'/'1d', or an ISO timestamp."
            }
        }
        var runBudget: Int?
        if let raw = args["run_budget"] {
            guard let n = raw as? Int, n >= 1 else {
                return "Error: 'run_budget' must be a positive integer (1 = one-shot)."
            }
            if n == 1, CronSchedule.isRecurring(schedule) {
                return "Error: a one-shot (run budget 1) cannot have a recurring schedule — use a single ISO timestamp."
            }
            runBudget = n
        }
        var job = CronJob(name: name, schedule: schedule, prompt: prompt)
        if let script, !script.isEmpty { job.script = script }
        job.profile = context.profile.rawValue
        job.nextRunAt = CronSchedule.next(schedule, after: Date())
        if let runBudget {
            job.runBudget = runBudget
            job.runsRemaining = runBudget
        }
        if let deliver = args["deliver"] as? String { job.deliver = deliver }
        if let script = args["script"] as? String {
            try CronOps.vetScriptPublic(script)
            job.script = script.isEmpty ? nil : script
        }
        if let refs = args["context_from"] as? [String] {
            // Unknown ids tolerated: dependency-order creation is fine;
            // injection skips absent upstreams.
            job.contextFrom = refs.isEmpty ? nil : refs
        }
        if let reset = args["resetEveryRuns"] as? String, let n = Int(reset) {
            job.resetEveryRuns = n > 0 ? n : nil
        }
        try await store.save(job)
        let next = job.nextRunAt.map { " Next run: \($0)." } ?? ""
        return "Created job '\(name)' (\(job.id)). Schedule: \(schedule).\(next)"
    }

    private static func performEdit(_ args: [String: Any], store: any CronStore) async throws -> String {
        guard let id = args["id"] as? String, !id.isEmpty else {
            return "Error: 'id' is required for edit."
        }
        guard var job = try await store.get(id: id) else {
            return "Error: no such job: \(id)"
        }
        if let rawSchedule = args["schedule"] as? String {
            let schedule = rawSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
            if schedule.isEmpty {
                // Clearing the schedule turns the job into a schedule-less
                // manual job: never auto-fires, Idle in the web UI.
                job.schedule = ""
                job.nextRunAt = nil
            } else {
                guard CronSchedule.isValid(schedule) else {
                    return "Error: invalid schedule '\(schedule)' — job left untouched."
                }
                let effectiveBudget = (args["run_budget"] as? Int) ?? job.runBudget
                if effectiveBudget == 1, CronSchedule.isRecurring(schedule) {
                    return "Error: a one-shot (run budget 1) cannot have a recurring schedule — job left untouched."
                }
                job.schedule = schedule
                job.nextRunAt = CronSchedule.next(schedule, after: Date())
            }
        }
        if let raw = args["run_budget"] {
            guard let n = raw as? Int, n >= 1 else {
                return "Error: 'run_budget' must be a positive integer (1 = one-shot)."
            }
            if n == 1, CronSchedule.isRecurring(job.schedule) {
                return "Error: a one-shot (run budget 1) cannot have a recurring schedule — job left untouched."
            }
            job.runBudget = n
            job.runsRemaining = n
        }
        if let name = args["name"] as? String, !name.isEmpty { job.name = name }
        if let prompt = args["prompt"] as? String, !prompt.isEmpty { job.prompt = prompt }
        if let deliver = args["deliver"] as? String { job.deliver = deliver.isEmpty ? nil : deliver }
        if let script = args["script"] as? String {
            try CronOps.vetScriptPublic(script)
            job.script = script.isEmpty ? nil : script
        }
        if let refs = args["context_from"] as? [String] {
            // Unknown ids tolerated: dependency-order creation is fine;
            // injection skips absent upstreams.
            job.contextFrom = refs.isEmpty ? nil : refs
        }
        try await store.save(job)
        let next = job.nextRunAt.map { " Next run: \($0)." } ?? ""
        return "Edited job \(id). Schedule: \(job.schedule).\(next)"
    }

    private static func performList(store: any CronStore) async throws -> String {
        let jobs = try await store.listAll()
        if jobs.isEmpty { return "No scheduled jobs." }
        let now = Date()
        let lines = jobs.map { job -> String in
            let state = job.isActive ? "active" : "paused"
            let due = CronOps.isDue(job, now: now) ? " [DUE NOW]" : ""
            let next = job.nextRunAt.map { ", next \($0)" } ?? ""
            return "• \(job.id.prefix(8)) \(job.name) — \(job.schedule) [\(state)\(next)]\(due): "
                + String(job.prompt.prefix(120))
        }
        return "\(jobs.count) job(s):\n" + lines.joined(separator: "\n")
    }

    private static func performSimple(
        _ args: [String: Any],
        store: any CronStore,
        _ body: (String) async throws -> String
    ) async throws -> String {
        guard let id = args["id"] as? String, !id.isEmpty else {
            return "Error: 'id' is required."
        }
        return try await body(id)
    }

    private static func performPause(_ id: String, store: any CronStore) async throws -> String {
        let job = try await CronOps.pause(store: store, id: id)
        return "Paused '\(job.name)' (\(job.id)) at \(job.pausedAt.map { "\($0)" } ?? "?")."
    }

    private static func performResume(_ id: String, store: any CronStore) async throws -> String {
        let job = try await CronOps.resume(store: store, id: id)
        let next = job.nextRunAt.map { " Next run: \($0)." } ?? ""
        return "Resumed '\(job.name)' (\(job.id)).\(next)"
    }

    private static func performRun(_ id: String, store: any CronStore) async throws -> String {
        let job = try await CronOps.runNow(store: store, id: id)
        return "Armed '\(job.name)' (\(job.id)) — fires on the next scheduler pass (≤30s)."
    }

    private static func performHistory(
        _ args: [String: Any],
        store: any CronStore,
        history: (any CronRunHistory)?
    ) async throws -> String {
        guard let id = args["id"] as? String, !id.isEmpty else {
            return "Error: 'id' is required for history."
        }
        guard try await store.get(id: id) != nil else {
            return "Error: no such job: \(id)"
        }
        guard let history else {
            return "Error: no run history is wired on this surface."
        }
        let limit = (args["limit"] as? String).flatMap(Int.init) ?? 10
        let runs = try await history.listRuns(jobID: id, limit: limit)
        if runs.isEmpty { return "No recorded runs for \(id)." }
        let lines = runs.map { run -> String in
            let status = run.status ?? "?"
            let err = run.error.map { " — \($0)" } ?? ""
            return "• \(run.startedAt) [\(status)] \(String(run.output.prefix(200)))\(err)"
        }
        return "\(runs.count) run(s) for \(id):\n" + lines.joined(separator: "\n")
    }
}
