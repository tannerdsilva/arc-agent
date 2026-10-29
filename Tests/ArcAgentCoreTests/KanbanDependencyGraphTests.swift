import Foundation
import Testing

@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// The dependency graph is what makes a board schedulable: `recomputeReady`
    /// only promotes a task once every parent is `done`. A cycle is therefore
    /// fatal in a quiet way — the tasks in it can never become ready, and the
    /// dispatcher never reports why.
    ///
    /// `addDependency` used to check one hop in each direction
    /// (`parent.parents.contains(child) || child.children.contains(parent)`),
    /// which catches only a two-task loop. Three tasks in a chain plus one
    /// closing edge sailed through and produced a permanently blocked board.
    /// These tests pin the transitive check, the self-edge, the duplicate
    /// no-op, and the legitimate diamond that must stay allowed.
    @Suite("Kanban dependency graph", .serialized)
    struct KanbanDependencyGraphTests {

        private func tempBoard() throws -> FileKanbanBoard {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-kanban-graph-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return FileKanbanBoard(directory: dir)
        }

        private func makeTasks(_ board: FileKanbanBoard, _ names: [String]) async throws -> [String: KanbanTask] {
            var created: [String: KanbanTask] = [:]
            for name in names {
                let task = KanbanTask(title: name, body: "")
                try await board.create(task)
                created[name] = task
            }
            return created
        }

        @Test("a three-hop cycle is refused")
        func transitiveCycleRefused() async throws {
            let board = try tempBoard()
            let t = try await makeTasks(board, ["A", "B", "C"])

            try await board.addDependency(parentID: t["A"]!.id, childID: t["B"]!.id)
            try await board.addDependency(parentID: t["B"]!.id, childID: t["C"]!.id)

            // C → A would close A → B → C → A: every task in the ring waits on
            // the next one and none is ever ready.
            await #expect(throws: KanbanError.self) {
                try await board.addDependency(parentID: t["C"]!.id, childID: t["A"]!.id)
            }

            // The refusal left the graph exactly as it was.
            let a = try await board.get(id: t["A"]!.id)
            let c = try await board.get(id: t["C"]!.id)
            #expect(a?.parents.isEmpty == true, "A gained a parent it must not have")
            #expect(c?.children.isEmpty == true, "C gained a child it must not have")
        }

        @Test("a task cannot depend on itself")
        func selfDependencyRefused() async throws {
            let board = try tempBoard()
            let t = try await makeTasks(board, ["A"])
            await #expect(throws: KanbanError.self) {
                try await board.addDependency(parentID: t["A"]!.id, childID: t["A"]!.id)
            }
        }

        @Test("adding the same dependency twice is a no-op, not a duplicate edge")
        func duplicateEdgeIsIdempotent() async throws {
            let board = try tempBoard()
            let t = try await makeTasks(board, ["A", "B"])

            try await board.addDependency(parentID: t["A"]!.id, childID: t["B"]!.id)
            try await board.addDependency(parentID: t["A"]!.id, childID: t["B"]!.id)

            let a = try await board.get(id: t["A"]!.id)
            let b = try await board.get(id: t["B"]!.id)
            #expect(a?.children == [t["B"]!.id])
            #expect(b?.parents == [t["A"]!.id])
        }

        @Test("a diamond dependency stays legal")
        func diamondAllowed() async throws {
            let board = try tempBoard()
            let t = try await makeTasks(board, ["A", "B", "C", "D"])

            try await board.addDependency(parentID: t["A"]!.id, childID: t["B"]!.id)
            try await board.addDependency(parentID: t["A"]!.id, childID: t["C"]!.id)
            try await board.addDependency(parentID: t["B"]!.id, childID: t["D"]!.id)
            try await board.addDependency(parentID: t["C"]!.id, childID: t["D"]!.id)

            let d = try await board.get(id: t["D"]!.id)
            #expect(d?.parents.count == 2, "D depends on both B and C")
        }
    }
}
