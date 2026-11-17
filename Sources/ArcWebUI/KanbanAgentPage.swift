import ArcAgentCore
import ArcTheme
import Foundation
import WebUI
import WebUIDesignSystem

// MARK: - Kanban agent page (spec 08)
//
// The board view renders server-side from a `BoardDocument`: lanes are rows,
// columns are the grid, cards render their contract summary, roots carry
// their termination state. No client state beyond disclosure/selection — the
// same structural-change-only liveness rules as the scheduled-tasks page.

extension AppState {

    // ── Derived accessors ────────────────────────────────────────────────

    /// The graph of the cached document (nil when nothing is loaded).
    var kbGraph: KanbanAgent.BoardGraph? {
        guard let doc = kanbanAgentDoc else { return nil }
        return KanbanAgent.BoardGraph(columns: doc.columns, edges: doc.edges)
    }

    /// Graph-health warnings from spec 02 §4: hard errors block the save
    /// path server-side; soft warnings render as the top-bar count.
    func kbValidation(doc: KanbanAgent.BoardDocument) -> [String] {
        KanbanAgent.BoardGraph(board: doc).validate().map { $0.description }
    }

    func kbCards(rootID: String) -> [KanbanAgent.Card] {
        kanbanAgentCards.filter { $0.rootID == rootID }
    }

    func kbCard(id: String) -> KanbanAgent.Card? {
        kanbanAgentCards.first { $0.id == id }
    }

    /// Readiness badge for a card.
    func kbReadiness(_ card: KanbanAgent.Card) -> String {
        if card.readiness == .done { return "done" }
        if card.result != nil { return "has result" }
        if !kbCards(rootID: card.rootID).filter({ $0.parentID == card.id && $0.readiness != .done }).isEmpty {
            return "waiting on children"
        }
        return "runnable"
    }

    // ── Page ─────────────────────────────────────────────────────────────

    /// The whole kanban-agent page. The top bar renders even for an empty or
    /// missing board so it can always be rebuilt in place.
    func kanbanAgentPage() -> some WebUI.View {
        Group {
            if let doc = kanbanAgentDoc {
                kanbanAgentBoard(doc)
            } else if let error = kanbanAgentError {
                MainView {
                    Div(class: ClassName(.kanbanMain, .mainView)) {
                        kanbanAgentTopbar(name: "Kanban")
                        Blank {
                            Big { WebUIIcon(.columns, size: .extraLarge) }
                            Div { Text("Could not load the board: \(error)") }
                        }
                    }
                    .attribute("style", "padding:0")
                }
            } else {
                MainView {
                    Div(class: ClassName(.kanbanMain, .mainView)) {
                        kanbanAgentTopbar(name: "Kanban")
                        Blank {
                            Big { WebUIIcon(.columns, size: .extraLarge) }
                            Div { Text("No board loaded — press + Column to create one.") }
                        }
                    }
                    .attribute("style", "padding:0")
                }
            }
        }
    }

    /// Top bar: board name left; "+ Column", "+ Row", "+ Root", a settings
    /// popover, and the graph-health indicator on the right.
    func kanbanAgentTopbar(name: String) -> some WebUI.View {
        let warn = kanbanAgentDoc.map { kbValidation(doc: $0) } ?? []
        let health: (String, String) = warn.isEmpty
            ? ("var(--ok)", "Graph healthy")
            : ("var(--warn)", "\(warn.count) graph warning\(warn.count == 1 ? "" : "s")")
        var popovers: [any View] = []
        if kanbanAgentPopover == "kba-addcol" { popovers.append(kbColumnForm()) }
        if kanbanAgentPopover == "kba-addrow" { popovers.append(kbLaneForm()) }
        if kanbanAgentPopover == "kba-addroot" { popovers.append(kbRootForm()) }
        if kanbanAgentPopover == "kba-settings" { popovers.append(kbSettingsForm()) }
        for col in kanbanAgentDoc?.columns ?? [] where kanbanAgentPopover == "kba-col-\(enc(col.id))" {
            popovers.append(kbColumnEditor(col))
        }
        return Div(class: .kbTopbar) {
            ErasedViews([
                Span(class: .kbTopbarName) { Text(name) },
                Div(class: .kbTopbarActions) {
                    ArcButton(id: "kba-dot", component: nil, class: .iconMini) {
                        Span {}
                            .attribute("style", "width:8px;height:8px;border-radius:4px;background:\(health.0);display:inline-block")
                    }
                    .title(health.1)
                    ArcButton("+ Column", id: "kba-addcol", component: nil, class: .ghostBtn)
                    ArcButton("+ Row", id: "kba-addrow", component: nil, class: .ghostBtn)
                    ArcButton("+ Root", id: "kba-addroot", component: nil, class: .ghostBtn)
                    ArcButton(id: "kba-settings", component: nil, class: .ghostBtn) { Text("Settings") }
                },
            ])
            ErasedViews(popovers)
        }
    }

    func kanbanAgentBoard(_ doc: KanbanAgent.BoardDocument) -> some WebUI.View {
        let lanes = doc.lanes
        let cols = doc.columns
        return MainView {
            Div(class: ClassName(.kanbanMain, .mainView)) {
                kanbanAgentTopbar(name: doc.name)
                if cols.isEmpty {
                    Blank {
                        Big { WebUIIcon(.columns, size: .extraLarge) }
                        Div { Text("No columns yet — open + Column to add one.") }
                    }
                } else if lanes.isEmpty {
                    Blank {
                        Big { WebUIIcon(.columns, size: .extraLarge) }
                        Div { Text("No lanes yet — open + Row to add one.") }
                    }
                } else {
                    Div(class: ClassName(.kbLanes, lanes.count <= 1 ? .kbLanesSingle : .kbLanes)) {
                        for lane in lanes {
                            ErasedViews([kbLaneRow(lane, cols, doc)])
                        }
                    }
                    .data("component-id", "kanban")
                    .data("event", "click")
                }
                for root in doc.roots {
                    ErasedViews([kbRootRow(root, doc: doc)])
                }
                if let sheetID = kanbanAgentSheetCard,
                   let card = kanbanAgentCards.first(where: { $0.id == sheetID }) {
                    ErasedViews([kbCardSheet(card, doc: doc)])
                }
            }
            .attribute("style", "padding:0")
        }
    }

    func kbLaneRow(_ lane: KanbanAgent.Lane, _ cols: [KanbanAgent.Column], _ doc: KanbanAgent.BoardDocument) -> some WebUI.View {
        Div(class: ClassName(.kbLane, doc.lanes.count <= 1 ? .kbLanesSingle : .kbLane)) {
            Div(class: .kbLaneHead) {
                Span(class: .kbLaneName) { Text(lane.name) }
                RowActions {
                    ArcButton(id: "kba-dellane-\(enc(lane.id))", component: nil, class: .iconMiniDanger) {
                        WebUIIcon(.x, size: .small)
                    }
                    .title("Delete row")
                }
            }
            Div(class: .kbLaneCols) {
                for col in cols {
                    ErasedViews([kbColumnCell(col, lane, doc)])
                }
            }
        }
    }

    func kbColumnCell(_ col: KanbanAgent.Column, _ lane: KanbanAgent.Lane, _ doc: KanbanAgent.BoardDocument) -> some WebUI.View {
        let cid = enc(col.id)
        let lid = enc(lane.id)
        let cards = kanbanAgentCards
            .filter { $0.columnID == col.id && $0.laneID == lane.id }
        return Div(class: .kbCol) {
            Div(class: .kbColHead) {
                ArcButton(id: "kba-colpop-\(cid)", component: nil, class: .kbPcol) {
                    LrName { Text(col.name) }
                    LrSub { Text("\(doc.edges.filter { $0.fromColumnID == col.id }.count) out · \(col.kind.rawValue)") }
                }
                Span(class: .kbColCount) { Text("\(cards.count)") }
            }
            for card in cards {
                ErasedViews([kbCardChip(card)])
            }
            ArcButton(id: "kba-addcard-\(cid)-\(lid)", component: nil, class: .ghostBtn) { Text("+ Card") }
        }
    }

    func kbCardChip(_ card: KanbanAgent.Card) -> some WebUI.View {
        let cid = enc(card.id)
        let readiness = kbReadiness(card)
        let running = card.readiness == .running
        return ArcButton(id: "kba-card-\(cid)", component: nil, class: running ? ClassName(.kbCard, .taskRunning) : .kbCard) {
            LrName { Text(card.goal) }
            LrSub { Text("\(readiness) · gen \(card.generation)") }
        }
        .attribute("style", "text-align:left")
    }

    // ── Popover forms ────────────────────────────────────────────────────

    func kbColumnForm() -> some WebUI.View {
        Form(action: "", method: nil, id: "kba-col-form", class: .catAddForm) {
            Input(field: "kba-col-name", placeholder: "Column name", type: .text,
                  attributes: [("data-component-id", "kba-col-name"), ("autofocus", "")])
            Input(field: "kba-col-kind", placeholder: "agentWork / humanWait / timerWait / terminal", type: .text,
                  attributes: [("data-component-id", "kba-col-kind")])
            CatAddActions {
                ArcButton("Add", class: .primaryBtn, type: .submit)
                ArcButton("Cancel", id: "kba-pop-close", component: nil, class: .ghostBtn)
            }
        }
        .data("component-id", "kba-col-form")
    }

    /// New-board form: lives in the left sidebar panel under the boards
    /// list (chat-row popover pattern — naming never shifts the panel).
    func kanbanNewBoardForm() -> some WebUI.View {
        Form(action: "", method: nil, id: "kba-newboard-form", class: .catAddForm) {
            Input(field: "kba-newboard-name", placeholder: "Board name", type: .text,
                  attributes: [("data-component-id", "kba-newboard-name"), ("autofocus", "")])
            CatAddActions {
                ArcButton("Create", class: .primaryBtn, type: .submit)
                ArcButton("Cancel", id: "kba-pop-close", component: nil, class: .ghostBtn)
            }
        }
        .data("component-id", "kba-newboard-form")
    }

    func kbLaneForm() -> some WebUI.View {
        Form(action: "", method: nil, id: "kba-lane-form", class: .catAddForm) {
            Input(field: "kba-lane-name", placeholder: "Row name", type: .text,
                  attributes: [("data-component-id", "kba-lane-name"), ("autofocus", "")])
            CatAddActions {
                ArcButton("Add", class: .primaryBtn, type: .submit)
                ArcButton("Cancel", id: "kba-pop-close", component: nil, class: .ghostBtn)
            }
        }
        .data("component-id", "kba-lane-form")
    }

    func kbRootForm() -> some WebUI.View {
        Form(action: "", method: nil, id: "kba-root-form", class: .catAddForm) {
            Input(field: "kba-root-title", placeholder: "Root title", type: .text,
                  attributes: [("data-component-id", "kba-root-title"), ("autofocus", "")])
            Input(field: "kba-root-dod", placeholder: "Definition of done (one clause per line)", type: .text,
                  attributes: [("data-component-id", "kba-root-dod")])
            CatAddActions {
                ArcButton("Create", class: .primaryBtn, type: .submit)
                ArcButton("Cancel", id: "kba-pop-close", component: nil, class: .ghostBtn)
            }
        }
        .data("component-id", "kba-root-form")
    }

    func kbSettingsForm() -> some WebUI.View {
        let s = kanbanAgentDoc?.settings
        func field(_ key: String, _ label: String, _ value: String) -> some WebUI.View {
            Div(class: .catAddForm) {
                Span(class: .lrSub) { Text(label) }
                Input(field: FieldID(key), type: .text, attributes: [("value", value), ("data-component-id", key)])
            }
        }
        return Form(action: "", method: nil, id: "kba-settings-form", class: .catAddForm) {
            field("kba-set-cycle", "Cycle budget", "\(s?.cycleBudget ?? 3)")
            field("kba-set-depth", "Max depth", "\(s?.maxDepth ?? 8)")
            field("kba-set-mint", "Mint allowance", "\(s?.mintAllowance ?? 25)")
            field("kba-set-stale", "Stale-motion timeout (s)", "\(Int(s?.staleMotionTimeoutSeconds ?? 600))")
            field("kba-set-cool", "Triage cooldown (s)", "\(Int(s?.triageCooldownSeconds ?? 300))")
            CatAddActions {
                ArcButton("Save", class: .primaryBtn, type: .submit)
                ArcButton("Cancel", id: "kba-pop-close", component: nil, class: .ghostBtn)
            }
        }
        .data("component-id", "kba-settings-form")
    }

    /// Per-column editor: rename, kind, outgoing edges, delete (arm-confirm).
    func kbColumnEditor(_ col: KanbanAgent.Column) -> some WebUI.View {
        let cid = enc(col.id)
        let edges = kanbanAgentDoc?.edges.filter { $0.fromColumnID == col.id } ?? []
        return Div(class: .catAddForm) {
            Span(class: .lrName) { Text("Edit \(col.name)") }
            Form(action: "", method: nil, id: "kba-col-edit-\(cid)", class: .catAddForm) {
                Input(field: "kba-col-edit-name", type: .text,
                      attributes: [("value", col.name), ("data-component-id", "kba-col-edit-name")])
                Input(field: "kba-col-edit-kind", type: .text,
                      attributes: [("value", col.kind.rawValue), ("data-component-id", "kba-col-edit-kind")])
                CatAddActions { ArcButton("Save", class: .primaryBtn, type: .submit) }
            }
            .data("component-id", "kba-col-edit-\(cid)")
            for edge in edges {
                ErasedViews([kbEdgeRow(edge)])
            }
            Form(action: "", method: nil, id: "kba-edge-form-\(cid)", class: .catAddForm) {
                Input(field: "kba-edge-to", placeholder: "To column id", type: .text,
                      attributes: [("data-component-id", "kba-edge-to")])
                Input(field: "kba-edge-label", placeholder: "Outcome label", type: .text,
                      attributes: [("data-component-id", "kba-edge-label")])
                CatAddActions { ArcButton("Add edge", class: .primaryBtn, type: .submit) }
            }
            .data("component-id", "kba-edge-form-\(cid)")
            RowActions {
                ArcButton(id: "kba-delcol-\(cid)", component: nil, class: .dangerBtn) { Text("Delete column") }
            }
        }
    }

    func kbEdgeRow(_ edge: KanbanAgent.Edge) -> some WebUI.View {
        RowActions {
            LrSub { Text("\(edge.id): →\(edge.toColumnID) [\(edge.decision.rawValue)\(edge.outcomeLabel.map { " \($0)" } ?? "")]") }
            ArcButton(id: "kba-deledge-\(enc(edge.id))", component: nil, class: .iconMiniDanger) {
                WebUIIcon(.x, size: .small)
            }
            .title("Delete edge")
        }
    }

    // ── Card sheet & root panel ──────────────────────────────────────────

    /// The card sheet: contract, lineage (read-only), provenance, counts,
    /// result, and the lane move control.
    func kanbanAgentCardSheet(_ card: KanbanAgent.Card) -> some WebUI.View {
        let cid = enc(card.id)
        return Div(class: .modalOverlay) {
            Div(class: .modalCard) {
                Heading(card.goal, level: .h3).id("kba-sheet-title")
                Paragraph("\(card.readiness.rawValue) · generation \(card.generation) · \(card.columnID)")
                for record in card.transitionProvenance {
                    ErasedViews([RowActions {
                        LrSub { Text("\(record.fromColumnID) → \(record.toColumnID) via \(record.edgeID) (\(record.decidedBy.rawValue)): \(record.reasoning)") }
                    }])
                }
                Paragraph("Traversal counts: " + card.traversalCounts.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: ", "))
                if let result = card.result {
                    Paragraph("Result: \(result.outcome) — \(result.summary)")
                }
                Form(action: "", method: nil, id: "kba-move-form-\(cid)", class: .catAddForm) {
                    Input(field: "kba-move-lane", type: .text,
                          attributes: [("value", card.laneID), ("data-component-id", "kba-move-lane")])
                    CatAddActions { ArcButton("Move", class: .primaryBtn, type: .submit) }
                }
                .data("component-id", "kba-move-form-\(cid)")
                Div(class: .modalActions) {
                    ArcButton("Close", id: "kba-sheet-close", component: nil, class: .ghostBtn)
                }
                .wire("kba-sheet")
            }
            .attribute("role", "dialog")
            .aria(.modal(.yes))
        }
    }

    /// Root panel rows: state chip, and for yellow roots the attempts
    /// timeline, what the user must provide, and the resume control
    /// (arm-confirm, with optional resume context).
    func kbRootRow(_ root: KanbanAgent.Root, doc: KanbanAgent.BoardDocument) -> some WebUI.View {
        let rid = enc(root.id)
        return Div(class: .listRow) {
            LrName { Text(root.title) }
            LrSub {
                Text("\(root.state.rawValue) · \(root.definitionOfDone.replacingOccurrences(of: "\n", with: " · "))")
            }
            if root.state == .yellow, let report = root.missingReport {
                for attempt in report.attempts {
                    ErasedViews([RowActions { LrSub { Text("attempt: \(attempt.whatWasTried) — \(attempt.outcome)") } }])
                }
                if let provision = report.userMustProvide.provisionLabel {
                    ErasedViews([RowActions { LrSub { Text("needed: \(provision)") } }])
                }
                RowActions {
                    ArcButton(id: "kba-resume-\(rid)", component: nil, class: .primaryBtn) { Text("Resume") }
                }
            }
            if root.state == .green, let chain = root.evidence {
                for entry in chain.entries {
                    ErasedViews([RowActions {
                        LrSub { Text("\(entry.clause) ← \(entry.cardIDs.joined(separator: ", ")): \(entry.reasoning)") }
                    }])
                }
            }
            RowActions {
                ArcButton(id: "kba-delroot-\(rid)", component: nil, class: .iconMiniDanger) {
                    WebUIIcon(.x, size: .small)
                }
                .title("Delete root")
            }
        }
    }
}

extension KanbanAgent.UserProvision {
    var provisionLabel: String? {
        switch self {
        case .decision(let d): return "decision — \(d)"
        case .credential(let c): return "credential — \(c)"
        case .information(let i): return "information — \(i)"
        case .capability(let c): return "capability — \(c)"
        }
    }
}

// MARK: - Actor-isolated mutations (called from the Controller)

extension AppState {

    /// Load (or reload) the board list and the selected document.
    func kbLoad() async {
        do {
            kanbanAgentBoards = try await kanbanAgentStore.listBoards()
            let id = kanbanAgentSelectedBoard ?? kanbanAgentBoards.first?.id ?? "default"
            if let doc = try await kanbanAgentStore.getBoard(id: id) {
                kanbanAgentDoc = doc
                kanbanAgentCards = try await kanbanAgentStore.cards(boardID: doc.id)
                kanbanAgentError = nil
            } else {
                kanbanAgentDoc = nil
                kanbanAgentCards = []
            }
        } catch {
            kanbanAgentError = error.localizedDescription
        }
    }

    /// Create a new board with the minimal legal seed graph — a triage
    /// intake column (entry), the mandatory ask-the-user column, and a Done
    /// terminal — then select it. The id is a slug made unique against the
    /// loaded boards.
    func kbCreateBoard(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let slug = trimmed.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" { if acc.last != "-" { acc.append(ch) } } else { acc.append(ch) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var id = slug.isEmpty ? "board" : slug
        var n = 2
        while kanbanAgentBoards.contains(where: { $0.id == id }) {
            id = "\(slug.isEmpty ? "board" : slug)-\(n)"
            n += 1
        }
        let intake = KanbanAgent.Column(name: "Intake", kind: .agentWork, isEntry: true, isTriage: true)
        let ask = KanbanAgent.Column(name: "Ask the user", kind: .humanWait)
        let done = KanbanAgent.Column(name: "Done", kind: .terminal)
        let doc = KanbanAgent.BoardDocument(
            id: id,
            name: trimmed,
            columns: [intake, ask, done],
            edges: [
                KanbanAgent.Edge(fromColumnID: intake.id, toColumnID: ask.id,
                    decision: .policy, policy: .agent, isAskTheUser: true),
                KanbanAgent.Edge(fromColumnID: ask.id, toColumnID: done.id, decision: .policy),
            ]
        )
        do {
            try await kanbanAgentStore.saveBoard(doc)
            kanbanAgentError = nil
            kanbanAgentSelectedBoard = doc.id
            await kbLoad()
        } catch {
            kanbanAgentError = error.localizedDescription
        }
    }

    /// Select a board and reload.
    func kbSelect(boardID: String) async {
        kanbanAgentSelectedBoard = boardID
        await kbLoad()
    }

    /// Apply a document mutation with server-side hard-rule validation; the
    /// UI never self-approves a graph edit (spec 08 §2).
    func kbApply(_ mutate: (inout KanbanAgent.BoardDocument) -> Void) async {
        guard var doc = kanbanAgentDoc else { return }
        mutate(&doc)
        doc.revision += 1
        let violations = KanbanAgent.BoardGraph(board: doc).hardViolations()
        guard violations.isEmpty else {
            kanbanAgentError = violations.map { $0.description }.joined(separator: "; ")
            return
        }
        do {
            try await kanbanAgentStore.saveBoard(doc)
            await kbLoad()
        } catch {
            kanbanAgentError = error.localizedDescription
        }
    }

    func kbSetPopover(_ popover: String?) { kanbanAgentPopover = popover }
    func kbTogglePopover(_ popover: String) {
        kanbanAgentPopover = kanbanAgentPopover == popover ? nil : popover
    }
    func kbSetSheet(_ id: String?) { kanbanAgentSheetCard = id }
    func kbSetError(_ error: String?) { kanbanAgentError = error }
    func kbArmConfirm(_ req: ConfirmRequest?) { pendingConfirm = req }
    /// Delete a root's cards from the store (the doc edit removes the root).
    func kbDeleteRootCards(rootID: String) async {
        let boardID = kanbanAgentDoc?.id
        for card in kanbanAgentCards where card.rootID == rootID {
            if let boardID { try? await kanbanAgentStore.deleteCard(id: card.id, boardID: boardID) }
        }
        kanbanAgentCards.removeAll { $0.rootID == rootID }
    }
}

extension AppState {

    /// Create a root plus its first card: the doc edit and the card save are
    /// one logical creation — the card's lane/column is chosen here so the
    /// first card lands in the board's agentWork entry column.
    func kbCreateRoot(_ root: KanbanAgent.Root, firstCard: KanbanAgent.Card) async {
        var placed = firstCard
        placed.laneID = kanbanAgentDoc?.lanes.first?.id ?? ""
        placed.columnID = kanbanAgentDoc?.columns.first(where: { $0.kind == .agentWork })?.id
            ?? kanbanAgentDoc?.columns.first?.id ?? ""
        await kbApply { doc in
            var r = root
            r.firstCardID = placed.id
            doc.roots.append(r)
        }
        if let doc = kanbanAgentDoc {
            try? await kanbanAgentStore.saveCard(placed, boardID: doc.id)
        }
    }
}

// MARK: - Card sheet (spec 08 §3)

extension AppState {

    func kbCardSheet(_ card: KanbanAgent.Card, doc: KanbanAgent.BoardDocument) -> some WebUI.View {
        let cid = enc(card.id)
        var rows: [any View] = []
        func row(_ label: String, _ value: String) {
            rows.append(Div(class: ClassName(.modalActions)) {
                Span { Text(label) }
                Span { Text(value) }
            })
        }
        row("Goal", card.goal)
        row("Done condition", card.doneCondition)
        if let input = card.input {
            row("Input (\(input.mode.rawValue))", input.payload.isEmpty ? input.sourceCardID : input.payload)
        }
        row("Column", doc.columns.first(where: { $0.id == card.columnID })?.name ?? card.columnID)
        row("Lane", doc.lanes.first(where: { $0.id == card.laneID })?.name ?? card.laneID)
        row("Readiness", kbReadiness(card))
        row("Generation", "\(card.generation)")
        if let parent = card.parentID { row("Parent", parent) }
        if let result = card.result {
            row("Outcome", result.outcome)
            row("Summary", result.summary)
        }
        for record in card.transitionProvenance {
            row("Moved", "\(record.edgeID): \(record.fromColumnID) → \(record.toColumnID) (\(record.decidedBy.rawValue)) — \(record.reasoning)")
        }
        for (column, count) in card.traversalCounts.sorted(by: { $0.key < $1.key }) {
            row("Visits: \(column)", "\(count)")
        }
        return Div(id: "kba-sheet-\(cid)", class: .modalOverlay) {
            Div(class: .modalCard) {
                Heading("Card", level: .h3)
                ErasedViews(rows)
                Div(class: .modalActions) {
                    ArcButton("Close", id: "kba-sheet-close", component: nil, class: .ghostBtn)
                }
            }
            .attribute("role", "dialog")
            .wire("kba-sheet")
        }
    }
}
