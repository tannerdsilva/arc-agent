import ArcAgentCore
import ArcTheme
import Foundation
import WebUI
import WebUIDesignSystem

// ==========================================================================
// Cards — the read-only view over the KanbanCards module.
//
// The web UI is a window, not a control surface: every kanban mutation
// runs through the `kanban` tool. This page renders what the tools did —
// boards, cards with status/priority/assignee, run history, comments,
// events, and attachment paths — and refreshes via the interval streamer
// only when the fingerprint moved, so an idle page sends no bytes.
// ==========================================================================

// MARK: - Snapshot model (Equatable for change detection)

struct CardBoardSnapshot: Equatable {
    struct TaskRow: Equatable {
        var id: String
        var title: String
        var status: String
        var priority: Int
        var assignee: String?
        var tenant: String?
        var blockKind: String?
        var blockRecurrences: Int
        var consecutiveFailures: Int
        var lastFailureError: String?
        var workspace: String
        var skills: [String]
        var created: String
        var started: String?
        var completed: String?
        var lastHeartbeat: String?
        var currentRun: String?
        var parents: [String]
        var children: [String]
        var runs: [RunRow]
        var comments: [CommentRow]
        var events: [String]
        var attachments: [String]

        struct RunRow: Equatable {
            var attempt: Int
            var id: String
            var status: String
            var outcome: String?
            var summary: String?
            var error: String?
        }
        struct CommentRow: Equatable {
            var author: String
            var body: String
        }
    }
    var board: String
    var tasks: [TaskRow]
}

// MARK: - Sync (called by the interval streamer)

extension AppState {

    /// Re-pull every board from the card store; returns true only when
    /// the rendered shape changed. Idle page ⇒ no broadcast.
    func syncKanbanCards() async -> Bool {
        let store = await CardStores.shared()
        var boards = Set<String>(["default"])
        if let fileStore = store as? FileCardStore {
            boards.formUnion(await fileStore.knownBoards())
        }
        var snapshot: [CardBoardSnapshot] = []
        for board in boards.sorted() {
            let tasks = (try? await store.listTasks(board: board, filter: CardListFilter(includeArchived: true, limit: 500))) ?? []
            var rows: [CardBoardSnapshot.TaskRow] = []
            for task in tasks {
                let runs = (try? await store.runs(taskID: task.id, board: board)) ?? []
                let comments = (try? await store.comments(taskID: task.id, board: board)) ?? []
                let events = (try? await store.events(taskID: task.id, board: board, limit: 8)) ?? []
                let atts = (try? await store.attachments(taskID: task.id, board: board)) ?? []
                let parents = (try? await store.parentIDs(of: task.id, board: board)) ?? []
                let children = (try? await store.childIDs(of: task.id, board: board)) ?? []
                rows.append(.init(
                    id: task.id, title: task.title, status: task.status.rawValue,
                    priority: task.priority, assignee: task.assignee, tenant: task.tenant,
                    blockKind: task.blockKind?.rawValue, blockRecurrences: task.blockRecurrences,
                    consecutiveFailures: task.consecutiveFailures, lastFailureError: task.lastFailureError,
                    workspace: task.workspacePath ?? "(scratch)",
                    skills: task.skills,
                    created: Self.stamp(task.createdAt), started: task.startedAt.map(Self.stamp),
                    completed: task.completedAt.map(Self.stamp), lastHeartbeat: task.lastHeartbeatAt.map(Self.stamp),
                    currentRun: task.currentRunID,
                    parents: parents, children: children,
                    runs: runs.map { .init(attempt: $0.attempt, id: String($0.id.prefix(8)), status: $0.status.rawValue,
                                           outcome: $0.outcome?.rawValue, summary: $0.summary.map { Self.excerpt($0, 300) },
                                           error: $0.error.map { Self.excerpt($0, 200) }) },
                    comments: comments.suffix(10).map { .init(author: $0.author, body: Self.excerpt($0.body, 400)) },
                    events: events.map { "\($0.kind)\($0.payload.map { ": \($0)" } ?? "")" },
                    attachments: atts.map { "\($0.filename) → \($0.storedPath)" }))
            }
            snapshot.append(.init(board: board, tasks: rows))
        }
        if snapshot == _cardSnapshot { return false }
        _cardSnapshot = snapshot
        return true
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    static func excerpt(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}

// MARK: - Rendering

extension AppState {

    /// Collapsed rail panel: counts only.
    func cardsPanel() -> some WebUI.View {
        Group {
            Element(.h2, class: .todoTitle) { Text("Cards") }
            if let snapshot = _cardSnapshot {
                let total = snapshot.reduce(0) { $0 + $1.tasks.count }
                let running = snapshot.flatMap(\.tasks).filter { $0.status == "running" }.count
                Element(.p, class: .todoSub) {
                    Text("\(total) card\(total == 1 ? "" : "s") · \(running) running")
                }
            } else {
                Element(.p, class: .todoSub) { Text("loading…") }
            }
        }
    }

    /// Main pane — one detail card per task, boards grouped under headers.
    func cardsMain() -> some WebUI.View {
        MainView {
            MainScroll {
                Element(.h2, class: .todoTitle) { Text("Cards") }
                Element(.p, class: .todoSub) {
                    Text("Read-only view — every kanban mutation runs through the `kanban` tool. Refreshes automatically.")
                }
                if let snapshot = _cardSnapshot, !snapshot.isEmpty {
                    ForEach1(snapshot) { board in cardsBoard(board) }
                } else {
                    Element(.p, class: .todoSub) {
                        Text("No cards yet. Ask the agent to create one — e.g. “create a kanban card titled Ship the thing, priority 2, assignee worker”.")
                    }
                }
            }
            .data("scroll-key", "cards-main")
        }
    }

    /// Map a view builder over an array — the house pattern (no ForEach).
    private func ForEach1<C: Collection>(_ items: C, _ body: (C.Element) -> any WebUI.View) -> some WebUI.View {
        Group { items.map { body($0) } }
    }

    private func cardsBoard(_ board: CardBoardSnapshot) -> any WebUI.View {
        Div(class: .taskGroup) {
            Div(class: .taskGroupHead) {
                Text("Board: \(board.board) — \(board.tasks.count) task\(board.tasks.count == 1 ? "" : "s")")
            }
            let rows: [(String, CardBoardSnapshot.TaskRow)] = board.tasks.map { ($0.id, $0) }
            Group { rows.map { cardRow($0.1) } }
        }
    }

    private func statusChip(_ status: String) -> any WebUI.View {
        // Reuse the tasks page chip vocabulary (chip[data-st=…]).
        let st: String
        switch status {
        case "running": st = "running"
        case "done": st = "completed"
        case "blocked", "triage": st = "failed"
        default: st = ""
        }
        return Span(class: .chip) { Text(status) }.data("st", st)
    }

    private func metaLine(_ parts: [String?]) -> any WebUI.View {
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return Div(class: .chatMeta) { Text(joined) }
    }

    private func cardRow(_ task: CardBoardSnapshot.TaskRow) -> any WebUI.View {
        // House pattern: every subview is bound before the builder —
        // `any View` values cannot be produced *inside* a result builder.
        let chip: [any WebUI.View] = [statusChip(task.status)]
        let assignee: [any WebUI.View] = task.assignee.map { a in [Span(class: .chatMeta) { Text("→ \(a)") }] } ?? []
        let tenant: [any WebUI.View] = task.tenant.map { t in [Span(class: .chatMeta) { Text("(tenant \(t))") }] } ?? []
        var metaParts: [String] = ["id \(task.id.prefix(8))", "workspace \(task.workspace)"]
        if task.currentRun != nil { metaParts.append("run live") }
        if let hb = task.lastHeartbeat { metaParts.append("heartbeat \(hb)") }
        let meta: [any WebUI.View] = [metaLine([metaParts.joined(separator: " · ")])]
        let skills: [any WebUI.View] = task.skills.isEmpty ? [] : [metaLine(["skills: \(task.skills.joined(separator: ", "))"])]
        let blockLine: [any WebUI.View] = task.blockKind.map { [metaLine(["block: \($0)\(task.blockRecurrences > 0 ? " ×\(task.blockRecurrences)" : "")"])] } ?? []
        let failLine: [any WebUI.View] = task.lastFailureError.map { [metaLine(["failures \(task.consecutiveFailures): \($0)"])] } ?? []
        let depLine: [any WebUI.View] = (task.parents.isEmpty && task.children.isEmpty) ? [] : [metaLine([
            "deps ← " + task.parents.map { String($0.prefix(8)) }.joined(separator: ", "),
            "gates → " + task.children.map { String($0.prefix(8)) }.joined(separator: ", "),
        ])]
        let runRows: [any WebUI.View] = task.runs.map { run in
            Div(class: .taskHistRow) {
                Span(class: .taskHistTime) { Text("#\(run.attempt) \(run.id)") }
                Span(class: .taskHistStatus) { Text("[\(run.status)]\(run.outcome.map { " \($0)" } ?? "")") }
                if let s = run.summary { Span(class: .chatMeta) { Text(s) } }
                if let e = run.error { Span(class: .chatMeta) { Text("(error: \(e))") } }
            }
        }
        let runsBlock: [any WebUI.View] = task.runs.isEmpty ? [] : [Div(class: .taskHistCard) {
            Div(class: .taskCtrlKey) { Text("Runs") }
            runRows
        }]
        let commentRows: [any WebUI.View] = task.comments.map { c in
            Div(class: .chatMeta) { Text("\(c.author): \(c.body)") }
        }
        let commentBlock: [any WebUI.View] = task.comments.isEmpty ? [] : [Div(class: .taskCtrlCard) {
            Div(class: .taskCtrlKey) { Text("Comments") }
            commentRows
        }]
        let attRows: [any WebUI.View] = task.attachments.map { a in
            Div(class: .chatMeta) { Text(a) }
        }
        let attBlock: [any WebUI.View] = task.attachments.isEmpty ? [] : [Div(class: .taskCtrlCard) {
            Div(class: .taskCtrlKey) { Text("Attachments") }
            attRows
        }]
        let eventRows: [any WebUI.View] = task.events.map { e in
            Div(class: .chatMeta) { Text(e) }
        }
        let eventBlock: [any WebUI.View] = task.events.isEmpty ? [] : [Div(class: .taskCtrlCard) {
            Div(class: .taskCtrlKey) { Text("Events") }
            eventRows
        }]
        return Div(class: .taskCtrlCard) {
            Div(class: .taskCtrlHead) {
                Div(class: .taskCtrlName) { Text("\(task.title)  ·  p\(task.priority)") }
                Div(class: .taskCtrlMeta) {
                    chip
                    assignee
                    tenant
                }
            }
            skills
            meta
            blockLine
            failLine
            depLine
            runsBlock
            commentBlock
            attBlock
            eventBlock
        }
    }
}
