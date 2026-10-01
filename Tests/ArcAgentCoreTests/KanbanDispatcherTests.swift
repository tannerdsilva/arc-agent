import Foundation
import Testing

@testable import ArcAgentCore

/// The dispatcher is a `Service`; this pins that `run()` polls the board on
/// its interval and exits on cancellation — the shape the daemon tree needs
/// from every leaf.
@Suite("Kanban dispatcher")
struct KanbanDispatcherTests {

    /// Records what the dispatcher asks of the board.
    private actor RecordingBoard: KanbanBoard {
        private var recomputeCount = 0
        private var listCount = 0

        func create(_ task: KanbanTask) async throws {}
        func get(id: String) async throws -> KanbanTask? { nil }
        func update(_ task: KanbanTask) async throws {}
        func delete(id: String) async throws {}
        func list(status: TaskStatus?, assignee: String?, limit: Int) async throws -> [KanbanTask] {
            listCount += 1
            return []
        }
        func transition(id: String, to newStatus: TaskStatus) async throws {}
        func addDependency(parentID: String, childID: String) async throws {}
        func recomputeReady() async throws { recomputeCount += 1 }

        func counts() -> (recompute: Int, list: Int) { (recomputeCount, listCount) }
    }

    @Test("run() polls on the interval and stops on cancellation")
    func pollsAndStops() async throws {
        let board = RecordingBoard()
        let dispatcher = KanbanDispatcher(board: board, pollIntervalSeconds: 1)

        let task = Task { try await dispatcher.run() }
        var counts = await board.counts()
        for _ in 0..<30 where counts.recompute < 2 {
            try await Task.sleep(for: .milliseconds(100))
            counts = await board.counts()
        }
        #expect(counts.recompute >= 2, "the dispatcher never polled twice: \(counts)")

        task.cancel()
        _ = try? await task.value
    }
}