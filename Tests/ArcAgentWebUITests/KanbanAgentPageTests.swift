import Testing
import Foundation
@testable import ArcWebUI
import ArcAgentCore

/// Kanban agent page (spec 08): the BoardDocument-backed board view —
/// top bar, lanes×columns grid, card chips, sheet, root panel and the
/// server-side hard-rule validation on graph edits.
@Suite("Kanban agent page")
struct KanbanAgentPageTests {

    private func makeApp(doc: KanbanAgent.BoardDocument?, cards: [KanbanAgent.Card] = [], boards: [KanbanAgent.BoardDocument] = [], popover: String? = nil, sheet: String? = nil, error: String? = nil) async -> AppState {
        var f = AppState.RenderFixture()
        f.kanbanAgentDoc = doc
        f.kanbanAgentCards = cards
        f.kanbanAgentBoards = boards
        let app = AppState(renderFixture: f)
        await app.kbSetPopover(popover)
        await app.kbSetSheet(sheet)
        await app.kbSetError(error)
        return app
    }

    /// The phase-4 board shape: entry → work → done + review/human, one
    /// running root with a first card.
    private func doc() -> (KanbanAgent.BoardDocument, [KanbanAgent.Card]) {
        var d = KanbanAgent.BoardDocument(name: "Relay Hardening")
        d.columns = [
            .init(id: "entry", name: "Entry", kind: .agentWork, isEntry: true),
            .init(id: "work", name: "Work", kind: .agentWork),
            .init(id: "done", name: "Done", kind: .terminal),
            .init(id: "review", name: "Triage", kind: .agentWork, isTriage: true),
            .init(id: "human", name: "Human", kind: .humanWait),
        ]
        d.edges = [
            .init(id: "e1", fromColumnID: "entry", toColumnID: "work", decision: .deterministic, outcomeLabel: "started"),
            .init(id: "e2", fromColumnID: "work", toColumnID: "done", decision: .deterministic, outcomeLabel: "completed"),
            .init(id: "e4", fromColumnID: "work", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
            .init(id: "e12", fromColumnID: "entry", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
            .init(id: "e13", fromColumnID: "review", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
        ]
        d.lanes = [.init(id: "l1", name: "Phase 1")]
        let root = KanbanAgent.Root(id: "r1", title: "Fix the relay wedge", definitionOfDone: "Relay restarts heal within 10 minutes.", firstCardID: "c1")
        d.roots = [root]
        let card = KanbanAgent.Card(id: "c1", laneID: "l1", columnID: "entry", readiness: .running,
            goal: "Reproduce the wedge", doneCondition: "Log evidence attached", parentID: nil, rootID: "r1")
        return (d, [card])
    }

    private func markup(_ app: AppState) async -> String {
        await app.kanbanAgentPage().markup.html
    }

    @Test("top bar renders board name, health dot and the three add buttons")
    func topbar() async {
        let (d, cards) = doc()
        let html = await markup(await makeApp(doc: d, cards: cards, boards: [d]))
        #expect(html.contains("Relay Hardening"))
        #expect(html.contains("kba-addcol"))
        #expect(html.contains("kba-addrow"))
        #expect(html.contains("kba-addroot"))
        #expect(html.contains("kba-settings"))
        #expect(html.contains("kba-dot"))
    }

    @Test("grid renders lanes as rows and columns with card chips")
    func grid() async {
        let (d, cards) = doc()
        let html = await markup(await makeApp(doc: d, cards: cards))
        #expect(html.contains("Phase 1"))
        #expect(html.contains("Entry"))
        #expect(html.contains("kba-card-\(enc("c1"))"))
        #expect(html.contains("Reproduce the wedge"))
        #expect(html.contains("kba-colpop-\(enc("entry"))"))
    }

    @Test("sheet renders the card contract, lineage and provenance")
    func sheet() async {
        let (d, cards) = doc()
        var provenance = cards[0]
        provenance.transitionProvenance = [KanbanAgent.TransitionRecord(
            edgeID: "e1", fromColumnID: "entry", toColumnID: "work",
            reasoning: "started", decidedBy: .deterministic, at: Date())]
        let html = await markup(await makeApp(doc: d, cards: [provenance], sheet: "c1"))
        #expect(html.contains("kba-sheet"))
        #expect(html.contains("Log evidence attached"))
        #expect(html.contains("started"))
        #expect(html.contains("e1"))
    }

    @Test("popover forms render for add-column and settings")
    func popovers() async {
        let (d, cards) = doc()
        let html = await markup(await makeApp(doc: d, cards: cards, popover: "kba-addcol"))
        #expect(html.contains("kba-col-form"))
        let settingsHTML = await markup(await makeApp(doc: d, cards: cards, popover: "kba-settings"))
        #expect(settingsHTML.contains("kba-set-cycle"))
        #expect(settingsHTML.contains("kba-set-depth"))
    }

    @Test("root panel shows green evidence, yellow report and resume arm")
    func rootPanel() async {
        var (d, cards) = doc()
        d.roots[0].state = .yellow
        d.roots[0].missingReport = KanbanAgent.MissingReport(
            attempts: [.init(cardID: "c1", whatWasTried: "Replayed the sync log", outcome: "No change observed")],
            blockingUnknown: "",
            userMustProvide: .information("Fresh run logs"),
            alternativesConsidered: ["prior report"])
        let html = await markup(await makeApp(doc: d, cards: cards))
        #expect(html.contains("Replayed the sync log"))
        #expect(html.contains("kba-resume-\(enc("r1"))"))
        d.roots[0].state = .green
        d.roots[0].evidence = KanbanAgent.EvidenceChain(entries: [KanbanAgent.EvidenceChain.Entry(
            clause: "Relay restarts heal within 10 minutes.", cardIDs: ["c1"], reasoning: "Log shows heal")])
        let greenHTML = await markup(await makeApp(doc: d, cards: cards))
        #expect(greenHTML.contains("Log shows heal"))
    }

    @Test("empty board renders the seeding hint")
    func emptyBoard() async {
        let html = await markup(await makeApp(doc: nil))
        #expect(html.contains("No board loaded"))
        let empty = await markup(await makeApp(doc: {
            var d = KanbanAgent.BoardDocument(name: "Empty")
            d.columns = [.init(id: "c", name: "C", kind: .agentWork)]
            return d
        }()))
        #expect(empty.contains("No lanes yet"))
    }

    @Test("load errors render verbatim")
    func errorRendering() async {
        let html = await markup(await makeApp(doc: nil, error: "store unavailable"))
        #expect(html.contains("store unavailable"))
    }

    @Test("card executor parses OUTCOME/SUMMARY and matches labels case-insensitively")
    func executorParsing() {
        let ok = KanbanAgent.SessionCardExecutor.parse("Did the thing.\nOUTCOME: completed\nSUMMARY: attached the log", expected: ["completed", "started"])
        #expect(ok.0 == "completed")
        #expect(ok.1 == "attached the log")
        let lax = KanbanAgent.SessionCardExecutor.parse("OUTCOME: COMPLETED", expected: ["completed"])
        #expect(lax.0 == "completed")
        let fallback = KanbanAgent.SessionCardExecutor.parse("just text", expected: ["started"])
        #expect(fallback.0 == "started")
    }

    // MARK: server-side validation

    private func scratchApp(_ d: KanbanAgent.BoardDocument, _ cards: [KanbanAgent.Card]) async -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kba-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileKanbanAgentStore(root: dir)
        try? await store.saveBoard(d)
        for card in cards { try? await store.saveCard(card, boardID: d.id) }
        var f = AppState.RenderFixture()
        f.kanbanAgentStore = store
        let app = AppState(renderFixture: f)
        await app.kbLoad()
        return app
    }

    @Test("kbApply refuses a hard-rule-violating edit and names the rule")
    func validationRefusal() async {
        let (d, cards) = doc()
        let app = await scratchApp(d, cards)
        await app.kbApply { doc in
            doc.edges.removeAll { $0.id == "e12" }  // entry loses its ask edge
        }
        let err = await app.kanbanAgentError
        #expect(err?.contains("ask") == true)
    }

    @Test("kbApply accepts a legal edit and bumps the revision")
    func validationAccept() async {
        let (d, cards) = doc()
        let app = await scratchApp(d, cards)
        await app.kbApply { doc in
            doc.lanes.append(KanbanAgent.Lane(name: "Phase 2"))
        }
        let err = await app.kanbanAgentError
        let doc = await app.kanbanAgentDoc
        #expect(err == nil)
        #expect(doc?.revision == d.revision + 1)
        #expect(doc?.lanes.count == 2)
    }
}
