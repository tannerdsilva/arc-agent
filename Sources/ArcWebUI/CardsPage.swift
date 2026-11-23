import ArcAgentCore
import ArcTheme
import Foundation
import Logging
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
        } else {
            // Tessera backend: the registry + any board with data on disk
            // (listBoards already folds both).
            if let registry = try? await store.listBoards() {
                boards.formUnion(registry.map(\.id))
            }
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

    /// Tab selection for a board ("board" default).
    func cardTab(_ board: String) -> String { cardTabs[board] ?? "board" }

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

    /// Main pane — one section per board: the fixed 5-column board view
    /// (one lane) plus a Completed tab for archived cards. Read-only: every
    /// mutation runs through the `kanban` tool; this page only reflects it.
    func cardsMain() -> some WebUI.View {
        MainView {
            MainScroll {
                Element(.h2, class: .todoTitle) { Text("Cards") }
                Element(.p, class: .todoSub) {
                    Text("Read-only view — every kanban mutation runs through the `kanban` tool. Boards have one lane and fixed columns: Todo, Ready, Running, Blocked, Finished. Refreshes automatically.")
                }
                if let snapshot = _cardSnapshot, !snapshot.isEmpty {
                    ForEach1(snapshot) { board in cardsBoardSection(board) }
                } else {
                    Element(.p, class: .todoSub) {
                        Text("No cards yet. Ask the agent to create one — e.g. “create a kanban card on board projects titled Ship the thing”.")
                    }
                }
            }
            .data("scroll-key", "cards-main")
            if let id = _cardDetailID,
               let task = _cardSnapshot?.flatMap(\.tasks).first(where: { $0.id == id }) {
                cardsDetailOverlay(task)
            }
        }
    }

    /// Map a view builder over an array — the house pattern (no ForEach).
    private func ForEach1<C: Collection>(_ items: C, _ body: (C.Element) -> any WebUI.View) -> some WebUI.View {
        Group { items.map { body($0) } }
    }

    private func cardsBoardSection(_ board: CardBoardSnapshot) -> any WebUI.View {
        let bid = enc(board.board)
        let tab = cardTab(board.board)
        // Wire the CONTAINER, not the buttons: the engine's clickTargetData
        // stops at the wired element itself, so targetId is only reported for
        // controls *inside* a wired wrapper (the clarify-choice pattern).
        let tabs: [any WebUI.View] = [
            ArcButton(id: "cards-tab-\(bid)-board", component: nil,
                      class: tab == "board" ? ClassName(.chip, .taskRunning) : .chip) { Text("Board") },
            ArcButton(id: "cards-tab-\(bid)-completed", component: nil,
                      class: tab == "completed" ? ClassName(.chip, .taskRunning) : .chip) { Text("Completed") },
        ]
        let archived = board.tasks.filter { $0.status == "archived" }
        return Div(class: .taskGroup) {
            Div(class: .taskGroupHead) {
                Text("\(board.board == CardBoard.standaloneID ? "Unboarded" : board.board) — \(board.tasks.filter { $0.status != "archived" }.count) on board · \(archived.count) completed")
                Div { ErasedViews(tabs) }.wire("cards-tab")
            }
            if tab == "completed" {
                if archived.isEmpty {
                    Element(.p, class: .todoSub) { Text("No completed cards yet — the dispatcher archives settled cards here.") }
                } else {
                    Div(class: .ccStack) { ErasedViews(archived.map { cardRow($0) }) }.wire("cards-chip")
                }
            } else {
                Div { ErasedViews([cardsLane(board)]) }.wire("cards-chip")
            }
        }
    }

    /// The fixed board: one lane, five hardcoded columns.
    private func cardsLane(_ board: CardBoardSnapshot) -> any WebUI.View {
        let columns: [any WebUI.View] = CardColumn.allCases.map { column in
            let inColumn = board.tasks.filter { task in
                guard let status = CardStatus(rawValue: task.status) else { return false }
                return CardColumn(status: status) == column
            }
            let chips: [any WebUI.View] = inColumn.map { cardChip($0) }
            return Div(class: .kbCol) {
                Div(class: .kbColHead) {
                    Span(class: .kbColName) { Text(column.displayName) }
                    Span(class: .kbColCount) { Text("\(inColumn.count)") }
                }
                if chips.isEmpty {
                    Span(class: .chatMeta) { Text("—") }
                } else {
                    Div(class: .ccStack) { ErasedViews(chips) }
                }
            }
        }
        return Div(class: .kbLanesSingle) {
            Div(class: .kbLane) {
                Div(class: .kbLaneHead) {
                    Span(class: .kbLaneName) { Text("Lane 1") }
                }
                Div(class: .kbLaneCols) { ErasedViews(columns) }
            }
        }
    }

    private func statusChip(_ status: String) -> any WebUI.View {
        // Reuse the tasks page chip vocabulary (chip[data-st=…]).
        let st: String
        switch status {
        case "running": st = "running"
        case "done", "archived": st = "completed"
        case "blocked", "triage": st = "failed"
        default: st = ""
        }
        return Span(class: .chip) { Text(status) }.data("st", st)
    }

    /// The uniform card chip: fixed-height box, thin status banner on top,
    /// title (ellipsized) + priority/assignee + status tag. Clickable — opens
    /// the detail panel (which carries runs, comments, attachments, events).
    private func cardChip(_ task: CardBoardSnapshot.TaskRow) -> any WebUI.View {
        let running = task.status == "running"
        let foot: [any WebUI.View] = [
            Span(class: .ccPriority) {
                Text("p\(task.priority)\(task.assignee.map { " · \($0)" } ?? "")")
            },
            Span(class: running ? ClassName(.ccTag, .ccTagRunning) : .ccTag) { Text(task.status) },
        ]
        return ArcButton(id: "cards-chip-\(enc(task.id))", component: nil, class: .ccCard) {
            Div(class: .ccBanner) {}
            Div(class: .ccBody) {
                Div(class: .ccTitle) { Text(task.title) }
                Div(class: .ccFoot) { ErasedViews(foot) }
            }
        }
        .data("st", task.status)
    }

    /// An archived card rendered like a board chip (same uniform design).
    private func cardRow(_ task: CardBoardSnapshot.TaskRow) -> any WebUI.View {
        cardChip(task)
    }

    /// Card detail: an overlay pinned to the main section — chrome and rail
    /// stay live. Backdrop click and the ✕ both close; clicks inside the
    /// panel carry the panel id and are ignored by the wire.
    func cardsDetailOverlay(_ task: CardBoardSnapshot.TaskRow) -> some WebUI.View {
        var meta: [any View] = []
        func row(_ key: String, _ value: String) {
            meta.append(Span(class: .cardsDetailKey) { Text(key) })
            meta.append(Span(class: .cardsDetailVal) { Text(value) })
        }
        row("id", "\(task.id.prefix(8))")
        row("status", task.status)
        row("priority", "p\(task.priority)")
        if let a = task.assignee { row("assignee", a) }
        if let t = task.tenant { row("tenant", t) }
        row("workspace", task.workspace)
        row("created", task.created)
        if let s = task.started { row("started", s) }
        if let c = task.completed { row("completed", c) }
        if let h = task.lastHeartbeat { row("heartbeat", h) }
        if let r = task.currentRun { row("current run", r) }
        if let b = task.blockKind { row("blocked", "\(b) × \(task.blockRecurrences)") }
        if task.consecutiveFailures > 0 { row("failures", "\(task.consecutiveFailures)") }
        if !task.skills.isEmpty { row("skills", task.skills.joined(separator: ", ")) }
        if !task.parents.isEmpty { row("parents", task.parents.joined(separator: ", ")) }
        if !task.children.isEmpty { row("children", task.children.joined(separator: ", ")) }
        var sections: [any View] = []
        if let err = task.lastFailureError {
            sections.append(Div(class: .cardsDetailSec) {
                Span(class: .cardsDetailKey) { Text("Last failure") }
                Span(class: .cardsDetailVal) { Text(err) }
            })
        }
        if !task.runs.isEmpty {
            sections.append(Div(class: .cardsDetailSec) {
                Span(class: .cardsDetailKey) { Text("Runs") }
                ErasedViews(task.runs.map { run in
                    Div(class: .chatMeta) {
                        Text("#\(run.attempt) \(run.id) [\(run.status)]\(run.outcome.map { " \($0)" } ?? "")")
                    }
                })
            })
        }
        for (title, lines) in [("Comments", task.comments.map { "\($0.author): \($0.body)" }),
                               ("Attachments", task.attachments),
                               ("Events", task.events)] where !lines.isEmpty {
            sections.append(Div(class: .cardsDetailSec) {
                Span(class: .cardsDetailKey) { Text(title) }
                ErasedViews(lines.map { line in Div(class: .chatMeta) { Text(line) } })
            })
        }
        let chip: [any View] = [statusChip(task.status)]
        return Div(id: "cards-detail-overlay", class: .cardsDetailOverlay) {
            Div(id: "cards-detail-panel", class: .cardsDetailPanel) {
                Div(class: .cardsDetailHead) {
                    Span(class: .cardsDetailTitle) { Text(task.title) }
                    ErasedViews(chip)
                    ArcButton(id: "cards-detail-close", component: "cards-detail-close", class: ClassName(.cardsDetailClose, .iconMini)) {
                        WebUIIcon(.x, size: .small)
                    }
                    .title("Close")
                }
                Div(class: .cardsDetailGrid) { ErasedViews(meta) }
                ErasedViews(sections)
            }
        }
        .wire("cards-detail")
    }
}
