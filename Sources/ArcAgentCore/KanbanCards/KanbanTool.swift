import Foundation
import Logging

// ==========================================================================
// KanbanTool — the unified `kanban` tool surface.
//
// Everything kanban runs through this one tool: no web UI buttons, no
// CLI verbs. It replaces the five legacy `kanban_*` registrations and
// the worker-only `card_complete`/`card_block` pair.
//
// Env-awareness mirrors the reference agent: in a dispatch-worker
// session (`ARC_KANBAN_TASK_ID` set) `task_id` and `run_id` default to
// the worker's own task, so the worker calls
// `kanban(action: "complete")` with no ids at all. Orchestrator
// sessions pass ids explicitly and get the full action set.
//
// The `run` action IS the dispatcher: claim the task, spawn a plain
// `arc chat -q` one-shot with the card identity in its environment,
// and record the spawn. The child posts through the existing shared
// tessera tunnel — no new connection is ever built for a card.
// ==========================================================================

enum KanbanTool {

    static let allActions: [String] = [
        "create", "list", "show", "claim", "run", "complete", "block",
        "unblock", "link", "comment", "attach", "attachments", "heartbeat",
        "runs", "events", "recompute", "boards", "archive", "delete_board",
    ]

    static func entry(
        storeOverride: (any CardStore)? = nil,
        envOverride: [String: String]? = nil,
        dispatch: ToolDependency<@Sendable (String) async throws -> String>? = nil
    ) -> ToolEntry {
        let storeBox = StoreBox(storeOverride: storeOverride, envOverride: envOverride, dispatch: dispatch)
        return ToolEntry(
            name: "kanban",
            toolset: .kanban,
            description: """
            Kanban card operations — create, list, show, claim, run, complete, block, unblock, link, comment, attach, heartbeat, events, boards, archive, delete_board. Everything kanban goes through this tool.
            In a worker session, task_id and run_id default to your own assignment. `complete` needs a `summary` handoff (plus optional metadata/artifacts); `block` needs `kind` (dependency|needs_input|capability|transient) and `reason`; `run` dispatches a worker one-shot in the background.
            Boards are organizational containers for cards: `boards` with no `board` lists them; pass `board` + `name`/`description` to create one. Cards go on a board by passing `board` at create time (column: Todo by default, or `column` = Todo|Ready|Running|Blocked|Finished); cards without a board live in the standalone pool ("default" board, rendered "Unboarded"). `archive` removes a settled card from the board columns into the Completed tab.
            """,
            schema: .object(
                description: "Kanban card operation",
                properties: [
                    "action": .string(description: "One of: \(allActions.joined(separator: ", "))"),
                    "task_id": .string(description: "Task id (defaults to your worker assignment in worker sessions)"),
                    "board": .string(description: "Board id (create/list/show/run/move/…). Omitted → the standalone pool (\"default\", rendered Unboarded). For `boards`, the id of the board to create or show."),
                    "column": .string(description: "Placement column for a board card at create: Todo|Ready|Running|Blocked|Finished (default Todo on a named board)"),
                    "title": .string(description: "Task title (create)"),
                    "body": .string(description: "Full task description (create)"),
                    "assignee": .string(description: "Assignee profile name"),
                    "priority": .integer(description: "Priority; higher = more urgent"),
                    "tenant": .string(description: "Tenant/project namespace filter or value"),
                    "status": .string(description: "Status filter (list)"),
                    "include_archived": .boolean(description: "Include archived tasks (list)"),
                    "limit": .integer(description: "Max rows (list/events; default 50, max 200)"),
                    "summary": .string(description: "Structured handoff summary (complete)"),
                    "metadata": .object(description: "Machine-readable facts (complete), string values", properties: [:], required: []),
                    "artifacts": .array(description: "Absolute paths of deliverable files (complete)", items: .string(description: "Absolute file path")),
                    "created_cards": .array(description: "Task ids created during this run (complete)", items: .string(description: "Task id")),
                    "kind": .string(description: "Block kind: dependency|needs_input|capability|transient (block)"),
                    "reason": .string(description: "Why blocked (block)"),
                    "parent_id": .string(description: "Parent task id (link)"),
                    "child_id": .string(description: "Child task id (link)"),
                    "author": .string(description: "Comment author (comment)"),
                    "comment": .string(description: "Comment body (comment)"),
                    "filename": .string(description: "Attachment filename (attach)"),
                    "content_type": .string(description: "Attachment content type (attach)"),
                    "content_base64": .string(description: "Attachment bytes, base64 (attach)"),
                    "workspace_path": .string(description: "Workspace directory for the dispatched worker (run)"),
                    "workspace_kind": .string(description: "scratch|worktree|dir (create)"),
                    "max_runtime_seconds": .integer(description: "Runtime cap for dispatched workers (create/run)"),
                    "skills": .array(description: "Skills the worker should load (create)", items: .string(description: "Skill name")),
                    "yolo": .boolean(description: "Dispatch the worker with approvals off (run, default true)"),
                    "prompt": .string(description: "Optional worker prompt text (run)"),
                ],
                required: ["action"]
            ),
            handler: { args in
                try await handle(args: args, box: storeBox)
            },
            emoji: "🗂"
        )
    }

    /// Indirection so tests can inject a store without touching globals.
    final class StoreBox: @unchecked Sendable {
        let storeOverride: (any CardStore)?
        /// Test hook: per-entry env dictionary so parallel tests cannot
        /// leak worker-env defaults into each other (the process env is
        /// the production path and stays untouched).
        let envOverride: [String: String]?
        let dispatch: ToolDependency<@Sendable (String) async throws -> String>?
        init(
            storeOverride: (any CardStore)? = nil,
            envOverride: [String: String]? = nil,
            dispatch: ToolDependency<@Sendable (String) async throws -> String>? = nil
        ) {
            self.storeOverride = storeOverride
            self.envOverride = envOverride
            self.dispatch = dispatch
        }
    }

    // MARK: Argument helpers

    static func boardArg(_ args: [String: Any], env: [String: String]?) -> String {
        if let b = args["board"] as? String, !b.isEmpty { return b }
        return CardWorker.board(env)
    }

    static func taskIDArg(_ args: [String: Any], env: [String: String]?) -> String? {
        if let t = args["task_id"] as? String, !t.isEmpty { return t }
        return CardWorker.env(CardWorker.taskIDKey, override: env)
    }

    static func runIDArg(_ args: [String: Any], env: [String: String]?) -> String? {
        if let r = args["run_id"] as? String, !r.isEmpty { return r }
        return CardWorker.env(CardWorker.runIDKey, override: env)
    }

    static func metadataArg(_ args: [String: Any]) -> [String: String]? {
        guard let raw = args["metadata"] as? [String: Any], !raw.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String { out[k] = s }
            else if let n = v as? Int { out[k] = String(n) }
            else if let n = v as? Double { out[k] = String(n) }
            else if let b = v as? Bool { out[k] = b ? "true" : "false" }
            else { out[k] = String(describing: v) }
        }
        return out
    }

    static func blockKindArg(_ args: [String: Any]) throws -> CardBlockKind? {
        guard let raw = args["kind"] as? String, !raw.isEmpty else { return nil }
        guard let kind = CardBlockKind(rawValue: raw) else {
            throw CardToolError.invalidArgument("kind must be one of: \(CardBlockKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return kind
    }

    static func statusArg(_ args: [String: Any]) throws -> CardStatus? {
        guard let raw = args["status"] as? String, !raw.isEmpty else { return nil }
        guard let status = CardStatus(rawValue: raw) else {
            throw CardToolError.invalidArgument("status must be one of: \(CardStatus.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return status
    }

    static func workspaceKindArg(_ args: [String: Any]) throws -> CardWorkspaceKind {
        guard let raw = args["workspace_kind"] as? String, !raw.isEmpty else { return .scratch }
        guard let kind = CardWorkspaceKind(rawValue: raw) else {
            throw CardToolError.invalidArgument("workspace_kind must be one of: \(CardWorkspaceKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return kind
    }

    static func stringArray(_ args: [String: Any], _ key: String) -> [String] {
        (args[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    enum CardToolError: Error { case invalidArgument(String) }

    // MARK: Dispatch

    static func handle(args: [String: Any], box: StoreBox) async throws -> String {
        guard let action = args["action"] as? String, !action.isEmpty else {
            return "Error: action is required (one of: \(allActions.joined(separator: ", ")))"
        }
        // Worker sessions with a local daemon up route the call through the
        // daemon's own card store (`POST /v1/kanban`) instead of opening a
        // second tessera tunnel — the same-WG-key peer-index fight is the
        // whole reason this proxy exists. Any transport failure falls back
        // to the local store path below, unchanged. Daemon-side execution
        // passes a storeOverride, which skips this branch (no re-proxy).
        if box.storeOverride == nil {
            // Production passes no envOverride — the worker identity lives in
            // the process environment (ARC_KANBAN_*). Restrict the forwarded
            // env to arc's own keys; nothing else leaks to the daemon.
            let env = box.envOverride
                ?? ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("ARC_") }
            if env[CardWorker.taskIDKey] != nil {
                if let proxy = KanbanProxy.resolve() {
                    if let output = await proxy.forward(args: args, env: env) {
                        Logger(label: "arc.kanban-proxy").info("worker kanban '\(action)' served via daemon proxy")
                        return output
                    }
                    Logger(label: "arc.kanban-proxy").warning("worker kanban '\(action)': daemon proxy unreachable — using local store")
                } else {
                    Logger(label: "arc.kanban-proxy").info("worker kanban '\(action)': no daemon proxy configured — using local store")
                }
            }
        }

        let store: any CardStore
        if let override = box.storeOverride {
            store = override
        } else {
            store = await CardStores.shared()
        }
        let env = box.envOverride
        let board = boardArg(args, env: env)
        do {
            switch action {
            case "create": return try await create(args, store: store, board: board)
            case "list": return try await list(args, store: store, board: board)
            case "show": return try await show(args, store: store, board: board, env: env)
            case "claim": return try await claim(args, store: store, board: board, env: env)
            case "run": return try await dispatch(args, store: store, board: board, env: env, box: box)
            case "complete": return try await complete(args, store: store, board: board, env: env)
            case "block": return try await block(args, store: store, board: board, env: env)
            case "unblock": return try await unblock(args, store: store, board: board, env: env)
            case "link": return try await link(args, store: store, board: board)
            case "comment": return try await comment(args, store: store, board: board, env: env)
            case "attach": return try await attach(args, store: store, board: board, env: env)
            case "attachments": return try await listAttachments(args, store: store, board: board, env: env)
            case "heartbeat": return try await heartbeat(args, store: store, board: board, env: env)
            case "runs": return try await listRuns(args, store: store, board: board, env: env)
            case "events": return try await listEvents(args, store: store, board: board, env: env)
            case "recompute": return try await recompute(store: store, board: board)
            case "boards": return try await boards(args, store: store, board: board)
            case "archive": return try await archive(args, store: store, board: board, env: env)
            case "delete_board": return try await deleteBoard(store: store, board: board)
            default:
                return "Error: unknown action '\(action)'. One of: \(allActions.joined(separator: ", "))"
            }
        } catch let error as CardStoreError {
            return "Error: \(cardStoreMessage(error))"
        } catch let error as CardToolError {
            return "Error: \(error)"
        } catch {
            // Connection-level failures (tessera store errors) surface with
            // their own description, never a bare reflection dump.
            return "Error: \(error)"
        }
    }

    static func cardStoreMessage(_ error: CardStoreError) -> String {
        switch error {
        case .taskNotFound(let id): return "task not found: \(id)"
        case .runNotFound(let taskID, let runID): return "run \(runID) not found on task \(taskID)"
        case .taskNotClaimable(let id, let status): return "task \(id) is not claimable (status: \(status.rawValue)) — only ready tasks dispatch"
        case .taskNotRunning(let id, let status): return "task \(id) is not in a blockable/unblockable state (status: \(status.rawValue))"
        case .parentCycle(let parent, let child): return "link refused: \(parent) → \(child) would create a dependency cycle"
        case .parentNotFound(let id): return "task not found: \(id)"
        case .phantomCreatedCard(let id): return "created_cards verification failed: task \(id) does not exist (phantom reference)"
        case .attachmentWriteFailed(let path): return "attachment write failed: \(path)"
        case .invalidTransition(let why): return why
        }
    }

    // MARK: Actions

    static func create(_ args: [String: Any], store: any CardStore, board: String) async throws -> String {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return "Error: title is required for create."
        }
        // Column placement: a named board defaults to the first column
        // (Todo); the standalone pool keeps the dispatchable `.ready`
        // default. An explicit `column` always wins.
        let onNamedBoard = board != CardBoard.standaloneID
        var status: CardStatus = onNamedBoard ? .todo : .ready
        if let raw = args["column"] as? String, !raw.isEmpty {
            guard let col = CardColumn.parse(raw) else {
                return "Error: column must be one of \(CardColumn.allCases.map(\.displayName).joined(separator: ", "))."
            }
            status = col.status
        }
        let task = CardTask(
            title: title,
            body: args["body"] as? String,
            assignee: args["assignee"] as? String,
            status: status,
            priority: args["priority"] as? Int ?? 0,
            createdBy: CardWorker.env(CardWorker.taskIDKey) != nil ? "worker:\(CardWorker.env(CardWorker.taskIDKey)!)" : "agent",
            workspaceKind: try workspaceKindArg(args),
            workspacePath: args["workspace_path"] as? String,
            tenant: args["tenant"] as? String,
            maxRuntimeSeconds: args["max_runtime_seconds"] as? Int,
            skills: stringArray(args, "skills")
        )
        let created = try await store.createTask(task, board: board)
        return "Created task \(created.id) (\(created.status.rawValue)): \(created.title)"
    }

    static func list(_ args: [String: Any], store: any CardStore, board: String) async throws -> String {
        let filter = CardListFilter(
            assignee: args["assignee"] as? String,
            status: try statusArg(args),
            tenant: args["tenant"] as? String,
            includeArchived: args["include_archived"] as? Bool ?? false,
            limit: args["limit"] as? Int ?? 50
        )
        let tasks = try await store.listTasks(board: board, filter: filter)
        if tasks.isEmpty { return "No tasks match on board '\(board)'." }
        let rows = tasks.map { task in
            var line = "\(task.id)  [\(task.status.rawValue)] p\(task.priority)  \(task.title)"
            if let a = task.assignee { line += "  → \(a)" }
            if let t = task.tenant { line += "  (tenant \(t))" }
            return line
        }
        return """
        Board '\(board)' — \(tasks.count) task\(tasks.count == 1 ? "" : "s"):
        \(rows.joined(separator: "\n"))
        """
    }

    static func show(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required (or set it in the worker env)."
        }
        guard let task = try await store.getTask(id: id, board: board) else {
            throw CardStoreError.taskNotFound(id)
        }
        var lines: [String] = []
        lines.append("Task \(task.id): \(task.title)")
        lines.append("Status: \(task.status.rawValue)   Priority: \(task.priority)   Assignee: \(task.assignee ?? "-")")
        if let tenant = task.tenant { lines.append("Tenant: \(tenant)") }
        lines.append("Workspace: \(task.workspaceKind.rawValue) @ \(task.workspacePath ?? "-")")
        if let ws = CardWorker.env(CardWorker.workspaceKey), !ws.isEmpty { lines.append("Worker cwd: \(ws)") }
        if let maxRuntime = task.maxRuntimeSeconds { lines.append("Max runtime: \(maxRuntime)s") }
        if let created = task.createdBy { lines.append("Created by: \(created)") }
        if let body = task.body, !body.isEmpty {
            lines.append("")
            lines.append("Body:")
            lines.append(CardRules.cap(body, CardRules.contextMaxBodyBytes))
        }
        let parents = try await store.parentIDs(of: id, board: board)
        let children = try await store.childIDs(of: id, board: board)
        lines.append("")
        lines.append("Parents: \(parents.isEmpty ? "-" : parents.joined(separator: ", "))   Children: \(children.isEmpty ? "-" : children.joined(separator: ", "))")
        if let failure = task.lastFailureError {
            lines.append("Consecutive failures: \(task.consecutiveFailures)   Last error: \(failure)")
        }
        if task.blockKind != nil || task.blockRecurrences > 0 {
            lines.append("Block kind: \(task.blockKind?.rawValue ?? "none")   Recurrences: \(task.blockRecurrences)")
        }

        let runs = try await store.runs(taskID: id, board: board)
        if !runs.isEmpty {
            lines.append("")
            lines.append("Runs:")
            for run in runs {
                var line = "  #\(run.attempt) \(run.id.prefix(8)) [\(run.status.rawValue)]"
                if let outcome = run.outcome { line += " outcome=\(outcome.rawValue)" }
                if let summary = run.summary { line += " — \(CardRules.cap(summary, 400))" }
                if let error = run.error { line += " (error: \(CardRules.cap(error, 200)))" }
                lines.append(line)
            }
        }
        let comments = try await store.comments(taskID: id, board: board)
        if !comments.isEmpty {
            lines.append("")
            lines.append("Comments:")
            for c in comments.suffix(20) {
                lines.append("  \(c.author): \(CardRules.cap(c.body, 500))")
            }
        }
        let atts = try await store.attachments(taskID: id, board: board)
        if !atts.isEmpty {
            lines.append("")
            lines.append("Attachments:")
            for a in atts { lines.append("  \(a.filename) → \(a.storedPath)") }
        }
        let events = try await store.events(taskID: id, board: board, limit: 15)
        if !events.isEmpty {
            lines.append("")
            lines.append("Recent events:")
            for e in events {
                lines.append("  \(e.kind)\(e.payload.map { ": \($0)" } ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func claim(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required for claim."
        }
        let (task, run) = try await store.claimTask(id: id, board: board, profile: args["profile"] as? String)
        return "Claimed task \(task.id) — run #\(run.attempt) (\(run.id)). Dispatch a worker with action `run`, or work it in this session."
    }

    /// The dispatcher step: claim (if needed) + spawn a plain one-shot
    /// worker with the card identity stamped in its environment. The
    /// child reuses the shared tessera tunnel like every other arc
    /// surface; nothing here builds a connection.
    static func dispatch(
        _ args: [String: Any], store: any CardStore, board: String,
        env: [String: String]?, box: StoreBox
    ) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required for run."
        }
        var task = try await store.taskOrThrow(id: id, board: board)
        var run: CardRun
        if let explicitRun = runIDArg(args, env: env), let r = try await store.runs(taskID: id, board: board).first(where: { $0.id == explicitRun }) {
            run = r
        } else if task.status == .ready {
            (task, run) = try await store.claimTask(id: id, board: board, profile: "dispatcher")
        } else if task.status == .running, let active = task.currentRunID,
                  let r = try await store.runs(taskID: id, board: board).first(where: { $0.id == active }) {
            run = r
        } else {
            return "Error: task \(id) is \(task.status.rawValue), not dispatchable (claim requires ready)."
        }

        let prompt = args["prompt"] as? String ?? "work kanban task \(id)"

        // Preferred path: in-process one-shot through the process's
        // already-established tessera tunnel (the daemon's runner). No new
        // tunnel, no static-key contention. The briefing rides in the prompt.
        if let runner = box.dispatch?.get() {
            let briefing = try await CardWorker.workerContext(store: store, task: task, run: run)
            let workerPrompt = "\(briefing)\n\n---\nWorker instruction: \(prompt)\n\n"
                + "Close the loop through the kanban tool with action `complete` "
                + "(pass task_id \(id) and run_id \(run.id) explicitly — this session "
                + "has no worker env) or `block` with a kind and reason."
            let taskID = id
            let runID = run.id
            let b = board
            let summary = "in-process one-shot (run #\(run.attempt))"
            Task {
                do {
                    _ = try await runner(workerPrompt)
                } catch {
                    _ = try? await store.failTask(
                        id: taskID, board: b, runID: runID,
                        outcome: .crashed, error: error.localizedDescription)
                }
            }
            try await store.appendEvent(taskID: id, board: board, runID: run.id, kind: "spawned", payload: summary)
            return """
            Dispatched task \(id) — run #\(run.attempt) (\(run.id)) in the background via the in-process runner.
            The worker resolves its briefing and closes the loop through `kanban`. Poll with action `show`.
            """
        }

        let workspace = (args["workspace_path"] as? String) ?? task.workspacePath ?? WorkspacePath.root
        let executable = Self.currentExecutable()
        var env = "ARC_KANBAN_TASK_ID=\(shellEscaped(id)) ARC_KANBAN_RUN_ID=\(shellEscaped(run.id)) ARC_KANBAN_BOARD=\(shellEscaped(board))"
        if let ws = CardWorker.env(CardWorker.workspaceKey) { env += " ARC_KANBAN_WORKSPACE=\(shellEscaped(ws))" }
        // Distinct worker identity: pass the daemon's configured worker key
        // down so the child never roams the daemon's relay peer (the
        // shared-key echo-timeout cascade). Absent key → child inherits the
        // main identity, as before.
        if let workerKey = ProcessInfo.processInfo.environment["ARC_TESSERA_WORKER_PRIVATE_KEY"] {
            env += " ARC_TESSERA_WORKER_PRIVATE_KEY=\(shellEscaped(workerKey))"
        }
        let shellPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let yolo = args["yolo"] as? Bool ?? true
        let command = "\(env) \(executable) chat -q '\(shellPrompt)'\(yolo ? " --yolo" : "")"
        do {
            let sessionID = try await ProcessRegistry.shared.start(command: command, workdir: workspace)
            try await store.appendEvent(taskID: id, board: board, runID: run.id, kind: "spawned", payload: "session \(sessionID)")
            return """
            Dispatched task \(id) — run #\(run.attempt) (\(run.id)) in the background (session \(sessionID)).
            The worker one-shot resolves its own briefing and closes the loop through `kanban`. Poll with action `show` or the `process` tool.
            """
        } catch {
            let (_, _, tripped) = try await store.failTask(
                id: id, board: board, runID: run.id,
                outcome: .spawn_failed, error: error.localizedDescription)
            return "Error: spawn failed (\(error.localizedDescription))\(tripped ? " — circuit breaker tripped, task auto-blocked." : "")"
        }
    }

    static func complete(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required (or set it in the worker env)."
        }
        guard let runID = runIDArg(args, env: env) else {
            return "Error: no active run — complete must run inside a claimed worker session or pass run_id."
        }
        let summary = args["summary"] as? String ?? args["result"] as? String
        guard summary != nil, !(summary ?? "").isEmpty else {
            return "Error: complete requires a `summary` handoff (1-3 sentences of what was done)."
        }
        let createdCards = stringArray(args, "created_cards")
        let artifacts = stringArray(args, "artifacts")
        for artifact in artifacts {
            if !FileManager.default.fileExists(atPath: artifact) {
                return "Error: declared artifact does not exist on disk: \(artifact). Fix the path and retry — the task stays in flight."
            }
        }
        let (_, run) = try await store.completeTask(
            id: id, board: board, runID: runID,
            summary: summary, metadata: metadataArg(args),
            createdCards: createdCards, artifacts: artifacts)
        // Dependencies may now promote.
        let promoted = try await store.recomputeReady(board: board)
        var note = ""
        if !promoted.isEmpty { note = "\nPromoted to ready: \(promoted.joined(separator: ", "))" }
        return "Task \(id) completed (run #\(run.attempt)). Handoff recorded for downstream workers." + note
    }

    static func block(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required (or set it in the worker env)."
        }
        guard let reason = args["reason"] as? String, !reason.isEmpty else {
            return "Error: block requires a `reason` shown to the human on the board."
        }
        let kind = try blockKindArg(args)
        let (task, _) = try await store.blockTask(
            id: id, board: board, runID: runIDArg(args, env: env),
            kind: kind, reason: reason)
        switch task.status {
        case .todo:
            return "Task \(id) blocked on a dependency — routed to `todo`; it auto-resumes when its parents finish (no human needed)."
        case .triage:
            return "Task \(id) has been re-blocked for the same reason too many times — routed to `triage` for a human decision."
        default:
            return "Task \(id) blocked (\(kind?.rawValue ?? "untyped")): \(reason)"
        }
    }

    static func unblock(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required for unblock."
        }
        let task = try await store.unblockTask(id: id, board: board)
        return "Task \(id) unblocked → \(task.status.rawValue)."
    }

    static func link(_ args: [String: Any], store: any CardStore, board: String) async throws -> String {
        guard let parent = args["parent_id"] as? String, let child = args["child_id"] as? String else {
            return "Error: link requires parent_id and child_id."
        }
        try await store.link(parentID: parent, childID: child, board: board)
        return "Linked \(parent) → \(child)."
    }

    static func comment(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required for comment."
        }
        guard let body = args["comment"] as? String, !body.isEmpty else {
            return "Error: comment body is required."
        }
        let author = args["author"] as? String
            ?? (CardWorker.isWorkerRun ? "worker:\(CardWorker.env(CardWorker.taskIDKey)!)" : "agent")
        let c = try await store.addComment(taskID: id, board: board, author: author, body: body)
        return "Comment \(c.id.prefix(8)) added to \(id)."
    }

    static func attach(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required for attach."
        }
        guard let filename = args["filename"] as? String, !filename.isEmpty else {
            return "Error: attach requires filename."
        }
        guard let b64 = args["content_base64"] as? String, let data = Data(base64Encoded: b64) else {
            return "Error: attach requires content_base64 (valid base64 bytes)."
        }
        let att = try await store.attach(
            taskID: id, board: board, filename: filename,
            contentType: args["content_type"] as? String, data: data)
        return "Attached \(att.filename) (\(att.size ?? 0) bytes) → \(att.storedPath)"
    }

    static func listAttachments(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required for attachments."
        }
        let atts = try await store.attachments(taskID: id, board: board)
        if atts.isEmpty { return "No attachments on \(id)." }
        return atts.map { "\($0.id.prefix(8))  \($0.filename)  \(($0.size ?? 0)) B  \($0.storedPath)" }
            .joined(separator: "\n")
    }

    static func heartbeat(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required (or set it in the worker env)."
        }
        try await store.heartbeat(id: id, board: board, runID: runIDArg(args, env: env))
        return "Heartbeat recorded on \(id)."
    }

    static func listRuns(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required for runs."
        }
        let runs = try await store.runs(taskID: id, board: board)
        if runs.isEmpty { return "No runs on \(id)." }
        return runs.map { run in
            var line = "#\(run.attempt) \(run.id) [\(run.status.rawValue)]"
            if let outcome = run.outcome { line += " outcome=\(outcome.rawValue)" }
            if let summary = run.summary { line += " — \(CardRules.cap(summary, 200))" }
            return line
        }.joined(separator: "\n")
    }

    static func listEvents(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required for events."
        }
        let limit = args["limit"] as? Int ?? 50
        let events = try await store.events(taskID: id, board: board, limit: limit)
        if events.isEmpty { return "No events on \(id)." }
        return events.map { e in
            let run = e.runID.map { " (run #\($0.prefix(8)))" } ?? ""
            return "\(e.kind)\(run)\(e.payload.map { ": \($0)" } ?? "")"
        }.joined(separator: "\n")
    }

    static func recompute(store: any CardStore, board: String) async throws -> String {
        let promoted = try await store.recomputeReady(board: board)
        if promoted.isEmpty { return "No tasks promoted on '\(board)' — nothing gated and satisfied." }
        return "Promoted to ready: \(promoted.joined(separator: ", "))"
    }

    /// Move a card to a column. The dispatcher's repositioning verb: any
    /// column change that isn't the state machine's own claim/block/complete
    /// path (e.g. Todo → Ready promotion, re-opening a finished card).
    /// Refuses while a run is in flight — those close through complete/block.
    static func move(_ args: [String: Any], store: any CardStore, board: String) async throws -> String {
        guard let id = args["task_id"] as? String, !id.isEmpty else {
            return "Error: task_id is required for move."
        }
        guard let raw = args["column"] as? String, let column = CardColumn.parse(raw) else {
            return "Error: column must be one of \(CardColumn.allCases.map(\.displayName).joined(separator: ", "))."
        }
        var task = try await store.taskOrThrow(id: id, board: board)
        guard task.currentRunID == nil else {
            return "Error: task \(id) has a run in flight — close it with complete/block before moving."
        }
        guard task.status != .archived else {
            return "Error: task \(id) is archived — it is off the board. Create a new card instead."
        }
        let from = task.status.rawValue
        task.status = column.status
        if column == .finished, task.completedAt == nil { task.completedAt = Date() }
        if column != .finished { task.completedAt = nil }
        try await store.saveTask(task, board: board)
        try await store.appendEvent(taskID: id, board: board, runID: nil, kind: "moved", payload: "\(from) → \(task.status.rawValue)")
        return "Moved \(id.prefix(8)) to \(column.displayName) (\(from) → \(task.status.rawValue))."
    }

    static func deleteBoard(store: any CardStore, board: String) async throws -> String {
        try await store.deleteBoard(board: board)
        return "Deleted all kanban data on board '\(board)'."
    }

    // MARK: Boards & archive

    /// `boards` with no `board` arg lists the registry; with `board` (+
    /// optional `name`/`description`) it creates or shows one board.
    static func boards(_ args: [String: Any], store: any CardStore, board: String) async throws -> String {
        if args["board"] == nil {
            let all = try await store.listBoards()
            let rows = all.map { board in
                var line = "\(board.id) — \(board.name)"
                if let d = board.description { line += "  (\(d))" }
                return line
            }
            return "Boards (hardcoded: 1 lane, columns Todo/Ready/Running/Blocked/Finished):\n" + rows.joined(separator: "\n")
        }
        let wantsCreate = args["name"] != nil || args["description"] != nil
        if wantsCreate {
            let name = (args["name"] as? String) ?? board
            // The registry id is always the slug of the name — a `board`
            // argument is a convenience handle, never a raw id with spaces.
            let id = CardBoard.slug(name)
            guard !CardBoard.reserved.contains(id) else {
                return "Error: '\(id)' is reserved (the standalone pool) and cannot be created."
            }
            let existing = try await store.listBoards().first { $0.id == id }
            if let existing {
                // Idempotent: same id + name updates the description.
                let updated = CardBoard(id: existing.id, name: name, description: args["description"] as? String, createdAt: existing.createdAt)
                try await store.createBoard(updated)
                return "Board \(updated.id) updated (description)."
            }
            let created = CardBoard(id: id, name: name, description: args["description"] as? String)
            try await store.createBoard(created)
            return "Created board \(created.id) — columns are fixed: Todo, Ready, Running, Blocked, Finished. Add cards with action create + board \(created.id)."
        }
        guard let existing = try await store.listBoards().first(where: { $0.id == board }) else {
            return "Error: no board '\(board)'. List with action boards."
        }
        let tasks = try await store.listTasks(board: board, filter: CardListFilter(includeArchived: true, limit: 500))
        var byColumn: [CardColumn: Int] = [:]
        for task in tasks {
            if let col = CardColumn(status: task.status) { byColumn[col, default: 0] += 1 }
        }
        let counts = CardColumn.allCases.map { col in
            "\(col.displayName): \(byColumn[col] ?? 0)"
        }.joined(separator: "  ·  ")
        return """
        Board \(existing.id) (\(existing.name)) — \(tasks.count) card\(tasks.count == 1 ? "" : "s")
        Columns: \(counts)  (archived: \(tasks.filter { $0.status == .archived }.count))
        """
    }

    static func archive(_ args: [String: Any], store: any CardStore, board: String, env: [String: String]?) async throws -> String {
        guard let id = taskIDArg(args, env: env) else {
            return "Error: task_id is required for archive."
        }
        let task = try await store.archiveTask(id: id, board: board)
        return "Task \(task.id) (\(task.title)) archived — moved off the board to the Completed tab."
    }

    // MARK: Spawn helpers

    /// The arc binary to relaunch for worker one-shots: this process's
    /// own executable, resolved absolute.
    static func currentExecutable() -> String {
        let raw = CommandLine.arguments.first ?? "arc"
        if raw.hasPrefix("/") { return shellEscaped(raw) }
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = URL(fileURLWithPath: cwd).appendingPathComponent(raw).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return shellEscaped(candidate)
        }
        return shellEscaped(raw)
    }

    static func shellEscaped(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
