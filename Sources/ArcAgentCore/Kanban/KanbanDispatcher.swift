import Foundation
import ServiceLifecycle

/// A background service that dispatches ready kanban tasks.
///
/// The ``KanbanDispatcher`` polls the kanban board for tasks in the `ready`
/// state and transitions them to `running`. In a full implementation, this
/// would spawn subagents to execute the tasks.
///
/// ## Law of the Land
///
/// - **Second Law**: ``KanbanDispatcher`` is a ``Service`` in the lifecycle
///   tree. It runs until cancelled, polls on a configurable interval, and
///   shuts down gracefully.
public actor KanbanDispatcher: Service {

    private let board: any KanbanBoard
    private let pollInterval: UInt64

    /// Create a kanban dispatcher.
    ///
    /// - Parameters:
    ///   - board: The kanban board to dispatch from.
    ///   - pollIntervalSeconds: How often to poll for ready tasks (default 5s).
    public init(board: any KanbanBoard, pollIntervalSeconds: UInt64 = 5) {
        self.board = board
        self.pollInterval = pollIntervalSeconds * 1_000_000_000
    }

    public func run() async throws {
        print("Kanban dispatcher started (poll interval: \(pollInterval / 1_000_000_000)s)")

        while !Task.isCancelled {
            do {
                try await board.recomputeReady()
                let readyTasks = try await board.list(status: .ready, assignee: nil, limit: 10)

                for task in readyTasks {
                    print("  Dispatching task: \(task.title.prefix(60))")
                    try await board.transition(id: task.id, to: .running)

                    // In a full implementation, this would spawn a subagent.
                    // For now, simulate work and mark as done.
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1s placeholder
                    try await board.transition(id: task.id, to: .done)
                }
            } catch {
                // Log and continue on transient errors
            }

            try await Task.sleep(nanoseconds: pollInterval)
        }

        print("Kanban dispatcher stopped.")
    }
}
