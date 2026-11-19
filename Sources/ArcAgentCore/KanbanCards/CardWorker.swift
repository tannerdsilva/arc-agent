import Foundation

/// The worker side of the card protocol.
///
/// A dispatch attempt is a plain terminal one-shot:
///
///     arc chat -q "work kanban task <id>"
///
/// launched with the card's identity in the environment. On startup the
/// CLI detects `ARC_KANBAN_TASK_ID`, resolves the task + run through the
/// same store the orchestrator used (tessera when configured — the
/// existing shared tunnel; no per-card connection is ever built), and
/// prepends a bounded worker context to the prompt. The dispatcher never
/// builds prompts and the worker needs no special syntax.
///
/// The worker ends its run through the `kanban` tool (actions `complete`
/// / `block` / `heartbeat`, env-defaulted to its own task); every other
/// failure path is the dispatcher's probes, not the worker's problem.
public enum CardWorker {

    // MARK: Environment contract

    /// The claimed task's ID.
    public static let taskIDKey = "ARC_KANBAN_TASK_ID"
    /// The active run's ID (validates the worker's transitions).
    public static let runIDKey = "ARC_KANBAN_RUN_ID"
    /// The workspace the worker was pinned to (informational, echoed in
    /// the briefing so the model knows where it is).
    public static let workspaceKey = "ARC_KANBAN_WORKSPACE"
    /// The board namespace the task lives in (defaults to `default`).
    public static let boardKey = "ARC_KANBAN_BOARD"

    /// Test seam: when set, these values take precedence over the
    /// process environment (tests must not mutate the real env).

    static func env(_ key: String, override: [String: String]? = nil) -> String? {
        if let override { return override[key] }
        return ProcessInfo.processInfo.environment[key]
    }

    /// Whether the current process is a card worker run.
    public static var isWorkerRun: Bool { env(taskIDKey) != nil }

    static func board(_ override: [String: String]? = nil) -> String {
        let b = env(boardKey, override: override) ?? "default"
        return b.isEmpty ? "default" : b
    }

    // MARK: Resolution

    public enum CardError: Error, Equatable {
        case notFound(String)
        case noActiveRun(String)
        case runBelongsToAnotherTask
    }

    /// Resolve the (task, run) the env claims, validating the pairing.
    public static func resolve(store: any CardStore) async throws -> (CardTask, CardRun) {
        let board = Self.board()
        guard let taskID = env(taskIDKey), !taskID.isEmpty else {
            throw CardError.notFound("no \(taskIDKey) in environment")
        }
        guard let runID = env(runIDKey), !runID.isEmpty else {
            throw CardError.noActiveRun(taskID)
        }
        guard let task = try await store.getTask(id: taskID, board: board) else {
            throw CardError.notFound(taskID)
        }
        let runs = try await store.runs(taskID: taskID, board: board)
        guard let run = runs.first(where: { $0.id == runID }) else {
            throw CardError.runBelongsToAnotherTask
        }
        return (task, run)
    }

    // MARK: Worker context

    /// Build the bounded worker context injected ahead of the prompt —
    /// the reference `build_worker_context` order:
    ///
    ///   1. Task header (id, title, assignee, status, workspace, caps).
    ///   2. Body (capped at 8 KB).
    ///   3. Attachments (absolute paths — the worker has file tools).
    ///   4. Prior attempts on this task (most recent N, older collapsed).
    ///   5. Done parents' structured handoffs (summary + metadata).
    ///   6. Cross-task role history (last 5 completed runs by assignee).
    ///   7. Comment thread (most recent 30, each capped).
    public static func workerContext(store: any CardStore, task: CardTask, run: CardRun) async throws -> String {
        let board = Self.board()
        var lines: [String] = []
        lines.append("# Kanban task \(task.id): \(task.title)")
        lines.append("")
        lines.append("Assignee: \(task.assignee ?? "(unassigned)")")
        lines.append("Status:   \(task.status.rawValue)")
        if let tenant = task.tenant {
            lines.append("Tenant:   \(tenant)")
        }
        let ws = env(workspaceKey) ?? task.workspacePath
        lines.append("Workspace: \(task.workspaceKind.rawValue) @ \(ws ?? "(unresolved)")")
        if let maxRuntime = task.maxRuntimeSeconds {
            lines.append("Max runtime: \(maxRuntime)s")
        }
        if let branch = task.branchName {
            lines.append("Branch:   \(branch)")
        }
        lines.append("")
        lines.append("Run \(run.attempt) (run ID: \(run.id)). End the run with exactly one terminal transition via the `kanban` tool:")
        lines.append("- action `complete` with a structured `summary` (human handoff) and optional `metadata` (machine-readable facts) and `artifacts` (absolute paths of deliverable files).")
        lines.append("- action `block` with a typed `kind` (dependency / needs_input / capability / transient) and `reason` when you cannot proceed.")
        lines.append("Do not call complete or block more than once.")
        lines.append("")

        if let body = task.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## Body")
            lines.append(CardRules.cap(body, CardRules.contextMaxBodyBytes))
            lines.append("")
        }

        // Attachments — surface absolute on-disk paths; the worker has
        // full file-tool access.
        let atts = try await store.attachments(taskID: task.id, board: board)
        if !atts.isEmpty {
            lines.append("## Attachments")
            lines.append("Files attached to this task. Read them with the file/terminal tools at the absolute paths below:")
            for att in atts {
                let sizeKB = att.size.map { max(1, ($0 + 1023) / 1024) }
                var desc = "- `\(att.filename)`"
                if let ct = att.contentType { desc += ", \(ct)" }
                if let kb = sizeKB { desc += ", \(kb) KB" }
                desc += " → `\(att.storedPath)`"
                lines.append(desc)
            }
            lines.append("")
        }

        // Prior attempts — closed runs, most recent N in full.
        let allRuns = try await store.runs(taskID: task.id, board: board)
        let priors = allRuns.filter { $0.id != run.id && $0.endedAt != nil }
        let omitted = max(0, priors.count - CardRules.contextMaxPriorAttempts)
        let shown = priors.suffix(CardRules.contextMaxPriorAttempts)
        if !shown.isEmpty {
            lines.append("## Prior attempts on this task")
            if omitted > 0 {
                lines.append("_(\(omitted) earlier attempt\(omitted == 1 ? "" : "s") omitted; showing most recent \(shown.count))_")
            }
            for prior in shown {
                let outcome = prior.outcome?.rawValue ?? prior.status.rawValue
                let profile = prior.profile ?? "(unknown)"
                lines.append("### Attempt \(prior.attempt) — \(outcome) (\(profile))")
                if let summary = prior.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    lines.append(CardRules.cap(summary, CardRules.contextMaxFieldBytes))
                }
                if let error = prior.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                    lines.append("_error_: \(CardRules.cap(error, CardRules.contextMaxFieldBytes))")
                }
                if let metadata = prior.metadata, !metadata.isEmpty {
                    let rendered = metadata.keys.sorted().map { "\($0): \(metadata[$0] ?? "")" }.joined(separator: "; ")
                    lines.append("_metadata_: `\(CardRules.cap(rendered, CardRules.contextMaxFieldBytes))`")
                }
                lines.append("")
            }
        }

        // Parent task results — point-in-time handoffs from done parents.
        let parentIDs = try await store.parentIDs(of: task.id, board: board)
        var wroteParents = false
        for pid in parentIDs {
            guard let parent = try await store.getTask(id: pid, board: board), parent.status == .done else { continue }
            let parentRuns = try await store.runs(taskID: pid, board: board).filter { $0.outcome == .completed }
            let handoff = parentRuns.last?.summary ?? parent.result ?? "(no result recorded)"
            if !wroteParents {
                lines.append("## Parent task results")
                lines.append("_Handoffs from upstream tasks, captured when each parent completed. These are point-in-time snapshots, not live state — re-verify against the source if the result drives your work._")
                wroteParents = true
            }
            lines.append("### \(pid)")
            lines.append(CardRules.cap(handoff, CardRules.contextMaxFieldBytes))
            lines.append("")
        }

        // Cross-task role history — last 5 completed runs by the assignee
        // on other tasks (so a specialist sees its own track record).
        if let assignee = task.assignee, !assignee.isEmpty {
            let boardTasks = try await store.listTasks(board: board, filter: CardListFilter(assignee: assignee, includeArchived: true, limit: 200))
            var roleRuns: [(task: String, run: CardRun)] = []
            for t in boardTasks where t.id != task.id {
                for r in try await store.runs(taskID: t.id, board: board) where r.outcome == .completed {
                    roleRuns.append((t.id, r))
                }
            }
            if !roleRuns.isEmpty {
                lines.append("## Recent work by this assignee on other tasks")
                for entry in roleRuns.suffix(5) {
                    let summary = entry.run.summary.flatMap { CardRules.cap($0, 200) } ?? "(no summary)"
                    lines.append("- \(entry.task): \(summary)")
                }
                lines.append("")
            }
        }

        // Comment thread — most recent N, each capped.
        let comments = try await store.comments(taskID: task.id, board: board)
        if !comments.isEmpty {
            lines.append("## Comments")
            let shownComments = comments.suffix(CardRules.contextMaxComments)
            let omittedComments = comments.count - shownComments.count
            if omittedComments > 0 {
                lines.append("_(\(omittedComments) earlier comment\(omittedComments == 1 ? "" : "s") omitted)_")
            }
            for comment in shownComments {
                lines.append("- **\(comment.author)**: \(CardRules.cap(comment.body, CardRules.contextMaxCommentBytes))")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Convenience: resolve from env and build the context.
    public static func workerContext(store: any CardStore) async throws -> String {
        let (task, run) = try await resolve(store: store)
        return try await workerContext(store: store, task: task, run: run)
    }

    /// Backward-compatible alias used by the CLI injection site.
    public static func briefing(store: any CardStore) async throws -> String {
        try await workerContext(store: store)
    }
}
