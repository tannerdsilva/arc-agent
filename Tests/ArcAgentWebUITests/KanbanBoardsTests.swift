import Testing
import Foundation
@testable import ArcWebUI

/// Multi-board kanban (Hermes parity): boards are rows in the side panel —
/// select, create, rename, delete — and every column/card is scoped to a
/// board. Legacy single-board data (nil `board`, empty `kanbanBoards`) reads
/// as one "Default" board without a migration write.
@Suite("Kanban boards")
struct KanbanBoardsTests {

    private func board(_ id: String, _ name: String) -> KBBoard {
        KBBoard(id: id, name: name)
    }

    private func makeApp(
        boards: [KBBoard] = [],
        columns: [KBColumn] = [],
        cards: [KBCard] = [],
        selected: String? = nil
    ) -> AppState {
        var f = AppState.RenderFixture()
        f.kanbanBoards = boards
        f.kanbanColumns = columns
        f.kanbanCards = cards
        f.kanbanSelectedBoard = selected
        return AppState(renderFixture: f)
    }

    // MARK: legacy derivation

    @Test("legacy single-board data derives a Default board and keeps its columns")
    func legacyDataDerivesDefaultBoard() {
        var s = AppSettings()
        s.kanbanColumns = [KBColumn(id: "c1", name: "Backlog", color: "#5BB98C")] // board: nil
        s.kanbanCards = [KBCard(id: "k1", columnID: "c1", title: "Legacy")]       // board: nil
        let out = AppState.ensureKanbanBoards(into: s)
        #expect(out.kanbanBoards == [board("default", "Default")])
        #expect(out.kanbanSelectedBoard == "default")
        // the legacy column is untouched and reads as the default board
        #expect(out.kanbanColumns.count == 1)
        #expect(AppState.boardID(out.kanbanColumns[0].board) == "default")
        #expect(AppState.boardID(out.kanbanCards[0].board) == "default")
    }

    @Test("a stale selection read from disk falls back to the first board")
    func staleSelectionFallsBack() {
        var s = AppSettings()
        s.kanbanBoards = [board("b1", "One")]
        s.kanbanSelectedBoard = "gone"
        let out = AppState.ensureKanbanBoards(into: s)
        #expect(out.kanbanSelectedBoard == "b1")
    }

    // MARK: create / select / rename

    @Test("creating a board selects it and seeds the three standard columns on it")
    func createSeedsAndSelects() async {
        let app = makeApp(boards: [board("default", "Default")], selected: "default")
        await app.addKanbanBoard(name: "  Release  ")
        let boards = await app.settings.kanbanBoards
        #expect(boards.count == 2)
        #expect(boards.last?.name == "Release")
        #expect(await app.selectedBoardID() == boards.last?.id)
        // the new board is immediately usable: three columns stamped to it
        let cols = await app.selectedKanbanColumns()
        #expect(cols.map { $0.name } == ["Backlog", "In progress", "Done"])
        #expect(cols.allSatisfy { AppState.boardID($0.board) == boards.last?.id })
    }

    @Test("a duplicate board name is refused and nothing is created")
    func duplicateNameRefused() async {
        let app = makeApp(boards: [board("b1", "Work")], selected: "b1")
        await app.addKanbanBoard(name: "work")   // case-insensitive
        let boards = await app.settings.kanbanBoards
        #expect(boards.count == 1)
        #expect(await app.selectedBoardID() == "b1")
    }

    @Test("an empty board name is refused")
    func emptyNameRefused() async {
        let app = makeApp(boards: [board("b1", "Work")], selected: "b1")
        await app.addKanbanBoard(name: "   ")
        #expect(await app.settings.kanbanBoards.count == 1)
    }

    @Test("rename trims, renames in place, and clears the rename state")
    func renameRoundTrip() async {
        let app = makeApp(boards: [board("b1", "Work"), board("b2", "Home")], selected: "b1")
        await app.renameKanbanBoard("b1", to: "  Deep Work  ")
        let boards = await app.settings.kanbanBoards
        #expect(boards.first?.name == "Deep Work")
        #expect(await app.renamingBoardID == nil)
        // a rename onto an existing name is refused
        await app.renameKanbanBoard("b1", to: "home")
        #expect(await app.settings.kanbanBoards.first?.name == "Deep Work")
    }

    // MARK: delete

    @Test("deleting a board removes only its columns and cards, and moves the selection")
    func deleteScopesToTheBoard() async {
        let app = makeApp(
            boards: [board("b1", "One"), board("b2", "Two")],
            columns: [
                KBColumn(id: "c1", name: "A", color: "#fff", board: "b1"),
                KBColumn(id: "c2", name: "B", color: "#fff", board: "b2"),
            ],
            cards: [
                KBCard(id: "k1", columnID: "c1", title: "one", board: "b1"),
                KBCard(id: "k2", columnID: "c2", title: "two", board: "b2"),
            ],
            selected: "b1")
        await app.selectKanbanBoard("b1")
        await app.setConfirmBoard("b1")
        await app.deleteKanbanBoard("b1")
        let s = await app.settings
        #expect(s.kanbanBoards.map { $0.id } == ["b2"])
        #expect(s.kanbanColumns.map { $0.id } == ["c2"])
        #expect(s.kanbanCards.map { $0.id } == ["k2"])
        #expect(await app.selectedBoardID() == "b2")
    }

    @Test("deleting the legacy default board also clears nil-board orphans")
    func defaultDeleteClearsLegacyOrphans() async {
        let app = makeApp(
            boards: [board("default", "Default"), board("b2", "Two")],
            columns: [
                KBColumn(id: "c1", name: "A", color: "#fff"),            // legacy nil
                KBColumn(id: "c2", name: "B", color: "#fff", board: "b2"),
            ],
            cards: [KBCard(id: "k1", columnID: "c1", title: "one")],     // legacy nil
            selected: "default")
        await app.deleteKanbanBoard("default")
        let s = await app.settings
        #expect(s.kanbanBoards.map { $0.id } == ["b2"])
        #expect(s.kanbanColumns.map { $0.id } == ["c2"])
        #expect(s.kanbanCards.isEmpty)
    }

    @Test("the last board cannot be deleted")
    func lastBoardRefused() async {
        let app = makeApp(boards: [board("b1", "Only")], selected: "b1")
        await app.deleteKanbanBoard("b1")
        #expect(await app.settings.kanbanBoards.count == 1)
        #expect(await app.selectedBoardID() == "b1")
    }

    // MARK: render

    @Test("the panel renders the boards section with the selected row and card counts")
    func panelRendersBoards() async {
        let app = makeApp(
            boards: [board("b1", "Work"), board("b2", "Home")],
            columns: [KBColumn(id: "c1", name: "A", color: "#fff", board: "b1"),
                      KBColumn(id: "c2", name: "B", color: "#fff", board: "b2")],
            cards: [KBCard(id: "k1", columnID: "c1", title: "one", board: "b1")],
            selected: "b2")
        let html = await app.kanbanPanel().markup.html
        #expect(html.contains("Boards"))
        #expect(html.contains("kb-sel-YjE") && html.contains("kb-sel-YjI"))  // base64("b1")/base64("b2")
        #expect(html.contains("1 card") && html.contains("0 cards"))
        // only the selected board's columns are listed
        #expect(html.contains("kb-pdel-YzI"))    // base64("c2")
        #expect(!html.contains("kb-pdel-YzE"))   // base64("c1")
    }

    @Test("the rename form renders inline for the armed board only")
    func renameFormRendersInline() async {
        let app = makeApp(boards: [board("b1", "Work")], selected: "b1")
        await app.setRenamingBoard("b1")
        let html = await app.kanbanPanel().markup.html
        #expect(html.contains("kb-board-ren-form"))
        #expect(html.contains("value=\"Work\""))
        #expect(!html.contains("kb-sel-YjE"))  // the row is replaced by the form
    }

    @Test("the main board shows only the selected board's columns")
    func mainShowsSelectedBoardOnly() async {
        let app = makeApp(
            boards: [board("b1", "One"), board("b2", "Two")],
            columns: [KBColumn(id: "c1", name: "A", color: "#fff", board: "b1"),
                      KBColumn(id: "c2", name: "B", color: "#fff", board: "b2")],
            selected: "b2")
        let html = await app.kanbanMain().markup.html
        #expect(html.contains("kb-col-name\">B"))
        #expect(!html.contains("kb-col-name\">A"))
    }
}
