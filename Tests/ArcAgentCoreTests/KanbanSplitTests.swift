import Foundation
import Testing
@testable import ArcAgentCore

// ==========================================================================
// KanbanSplitTests — the dispatcher's card-splitting primitive.
//
// The board agent decomposes a complex card (an entire app, a phased plan)
// into child phase cards via `kanban action: split`. The contract under
// test:
//   1. Children are created on the same board and linked under the parent.
//   2. The parent is marked done WITHOUT a run row — its prompt can never
//      execute (a later `run` on it must be refused as non-dispatchable).
//   3. Ungated children promote to Ready on the trailing recompute.
//   4. Refusals are atomic: a malformed subtask leaves the board untouched.
// Everything goes through the real tool surface (`KanbanTool.handle`) over
// a real `FileCardStore` — no mocks on the path under test.
// ==========================================================================

@Suite("Kanban split — decompose a complex card")
struct KanbanSplitTests {

    func makeStore() -> FileCardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-split-tests-\(UUID().uuidString)", isDirectory: true)
        return FileCardStore(arcHome: tmp)
    }

    func box(_ store: FileCardStore) -> KanbanTool.StoreBox {
        KanbanTool.StoreBox(storeOverride: store, envOverride: [:])
    }

    @Test("split creates linked children and marks the parent done with no run")
    func splitCreatesChildren() async throws {
        let store = makeStore()
        let board = "phase-board"
        let parent = try await store.createTask(
            CardTask(title: "Build the whole app", body: "Phased plan: scaffold, features, polish."),
            board: board)

        let output = try await KanbanTool.handle(args: [
            "action": "split",
            "board": board,
            "task_id": parent.id,
            "subtasks": [
                ["title": "Phase 1 — scaffold", "body": "Project skeleton", "priority": 2, "column": "Ready"],
                ["title": "Phase 2 — features", "body": "Core features", "priority": 1],
                ["title": "Phase 3 — polish", "body": "UX polish"],
            ],
        ], box: box(store))

        #expect(output.contains("WITHOUT a run"))
        // Parent: done, no run ever created.
        let doneParent = try #require(try await store.getTask(id: parent.id, board: board))
        #expect(doneParent.status == .done)
        #expect(doneParent.completedAt != nil)
        #expect(doneParent.currentRunID == nil)
        let runs = try await store.runs(taskID: parent.id, board: board)
        #expect(runs.isEmpty)
        // Children: created, linked, and present on the board.
        let childIDs = try await store.childIDs(of: parent.id, board: board)
        #expect(childIDs.count == 3)
        let all = try await store.listTasks(board: board, filter: CardListFilter(includeArchived: true))
        #expect(all.count == 4)
        let titles = Set(all.filter { $0.id != parent.id }.map(\.title))
        #expect(titles == ["Phase 1 — scaffold", "Phase 2 — features", "Phase 3 — polish"])
        // The split is auditable on the parent's event log.
        let events = try await store.events(taskID: parent.id, board: board, limit: 10)
        #expect(events.contains { $0.kind == "split" })
    }

    @Test("ungated children promote to Ready on the trailing recompute")
    func splitPromotesUngatedChildren() async throws {
        let store = makeStore()
        let board = "promote-board"
        let parent = try await store.createTask(CardTask(title: "complex effort"), board: board)
        _ = try await KanbanTool.handle(args: [
            "action": "split",
            "board": board,
            "task_id": parent.id,
            "subtasks": [
                ["title": "ungated", "column": "Todo"],
                ["title": "explicit ready", "column": "Ready"],
            ],
        ], box: box(store))
        let tasks = try await store.listTasks(board: board, filter: CardListFilter())
        let byTitle = Dictionary(uniqueKeysWithValues: tasks.map { ($0.title, $0.status) })
        // Both children are now dispatchable: the explicit Ready one and the
        // Todo one promoted because their only parent is done.
        #expect(byTitle["explicit ready"] == .ready)
        #expect(byTitle["ungated"] == .ready)
    }

    @Test("a split parent can never dispatch — run refuses non-ready")
    func splitParentNeverDispatches() async throws {
        let store = makeStore()
        let board = "guard-board"
        let parent = try await store.createTask(CardTask(title: "do not run me"), board: board)
        _ = try await KanbanTool.handle(args: [
            "action": "split", "board": board, "task_id": parent.id,
            "subtasks": [["title": "child"]],
        ], box: box(store))

        // Even if the aux model tries to run the split parent, the claim
        // guard refuses before any spawn: the prompt cannot execute.
        let output = try await KanbanTool.handle(args: [
            "action": "run", "board": board, "task_id": parent.id,
        ], box: box(store))
        #expect(output.contains("not dispatchable"))
        #expect(try await store.runs(taskID: parent.id, board: board).isEmpty)
    }

    @Test("split refuses a card with a run in flight")
    func splitRefusesRunningCard() async throws {
        let store = makeStore()
        let board = "running-board"
        let task = try await store.createTask(CardTask(title: "in flight", status: .ready), board: board)
        _ = try await store.claimTask(id: task.id, board: board, profile: "worker")
        let output = try await KanbanTool.handle(args: [
            "action": "split", "board": board, "task_id": task.id,
            "subtasks": [["title": "child"]],
        ], box: box(store))
        #expect(output.contains("run in flight"))
        // Nothing was created; the card is untouched.
        #expect(try await store.childIDs(of: task.id, board: board).isEmpty)
        #expect(try await store.getTask(id: task.id, board: board)?.status == .running)
    }

    @Test("split refuses done and archived parents")
    func splitRefusesSettledCards() async throws {
        let store = makeStore()
        let board = "settled-board"
        let done = try await store.createTask(CardTask(title: "done card", status: .done), board: board)
        let doneOutput = try await KanbanTool.handle(args: [
            "action": "split", "board": board, "task_id": done.id,
            "subtasks": [["title": "child"]],
        ], box: box(store))
        #expect(doneOutput.contains("already done"))

        let card = try await store.createTask(CardTask(title: "to archive", status: .done), board: board)
        _ = try await store.archiveTask(id: card.id, board: board)
        let archivedOutput = try await KanbanTool.handle(args: [
            "action": "split", "board": board, "task_id": card.id,
            "subtasks": [["title": "child"]],
        ], box: box(store))
        #expect(archivedOutput.contains("archived"))
    }

    @Test("a malformed subtask refuses the whole split atomically")
    func malformedSubtaskIsAtomic() async throws {
        let store = makeStore()
        let board = "atomic-board"
        let parent = try await store.createTask(CardTask(title: "complex effort"), board: board)
        let output = try await KanbanTool.handle(args: [
            "action": "split", "board": board, "task_id": parent.id,
            "subtasks": [
                ["title": "good child"],
                ["body": "no title here"],
                ["title": "bad column", "column": "Sideways"],
            ],
        ], box: box(store))
        #expect(output.contains("Error:"))
        // No children, no completion — the board is exactly as it was.
        #expect(try await store.childIDs(of: parent.id, board: board).isEmpty)
        #expect(try await store.getTask(id: parent.id, board: board)?.status != .done)
        let all = try await store.listTasks(board: board, filter: CardListFilter())
        #expect(all.count == 1)
    }

    @Test("split requires subtasks and a task id")
    func splitArgumentValidation() async throws {
        let store = makeStore()
        let board = "args-board"
        let missing = try await KanbanTool.handle(args: [
            "action": "split", "board": board, "task_id": "whatever",
        ], box: box(store))
        #expect(missing.contains("subtasks"))

        let task = try await store.createTask(CardTask(title: "x"), board: board)
        let noID = try await KanbanTool.handle(args: [
            "action": "split", "board": board, "subtasks": [["title": "c"]],
        ], box: box(store))
        #expect(noID.contains("task_id is required"))
        #expect(try await store.getTask(id: task.id, board: board)?.status != .done)
    }

    @Test("the dispatcher system prompt instructs splitting before running")
    func dispatcherPromptMentionsSplit() {
        let prompt = BoardDispatcherService.systemPrompt()
        #expect(prompt.contains("split"))
        #expect(prompt.contains("WITHOUT running its prompt"))
        #expect(prompt.contains("SPLIT"))
        // The duty list is now four entries, split first.
        #expect(prompt.range(of: "1. SPLIT") != nil)
        #expect(prompt.range(of: "4. CLEAN UP") != nil)
    }
}
