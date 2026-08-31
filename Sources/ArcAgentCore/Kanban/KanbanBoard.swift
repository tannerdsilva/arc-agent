import Foundation

/// A kanban board for tracking tasks and their lifecycle.
///
/// ``KanbanBoard`` is a **protocol** — the abstraction for task storage.
/// The default implementation is ``FileKanbanBoard`` (JSON files).
/// A Tessera-backed implementation may replace it once the Tessera store
/// surface covers kanban boards.
///
/// ## Status Lifecycle
///
/// ```
/// triage → todo → ready → running → review → done → archived
///                    ↓          ↓
///                 blocked → ready (when unblocked)
/// ```
///
/// ## Concurrency
///
/// ``KanbanBoard`` is ``Sendable``. Implementations are responsible for
/// their own synchronization. ``FileKanbanBoard`` uses an actor internally.
public protocol KanbanBoard: Sendable {
    /// Create a new task.
    /// - Throws: ``KanbanError/duplicateId`` if a task with the same ID exists.
    func create(_ task: KanbanTask) async throws

    /// Get a task by ID.
    func get(id: String) async throws -> KanbanTask?

    /// Update a task.
    func update(_ task: KanbanTask) async throws

    /// Delete a task.
    func delete(id: String) async throws

    /// List tasks with optional filters.
    func list(
        status: TaskStatus?,
        assignee: String?,
        limit: Int
    ) async throws -> [KanbanTask]

    /// Transition a task to a new status.
    /// - Throws: ``KanbanError/invalidTransition`` if the transition is not allowed.
    func transition(id: String, to newStatus: TaskStatus) async throws

    /// Add a parent-child dependency.
    /// - Throws: ``KanbanError/cycleDetected`` if adding would create a cycle.
    func addDependency(parentID: String, childID: String) async throws

    /// Recompute which tasks are ready (all parents done).
    func recomputeReady() async throws
}

/// Default status transitions.
///
/// Maps each status to the set of valid next statuses.
let defaultTransitions: [TaskStatus: Set<TaskStatus>] = [
    .triage: [.todo, .blocked],
    .todo: [.ready, .blocked],
    .ready: [.running, .blocked],
    .running: [.review, .blocked, .done],
    .blocked: [.ready, .todo, .triage],
    .review: [.done, .blocked],
    .done: [.archived],
    .archived: [],
]
