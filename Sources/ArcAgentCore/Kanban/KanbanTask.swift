import Foundation

/// The status of a kanban task.
public enum TaskStatus: String, Sendable, Codable, CaseIterable {
    /// Needs triage/specification.
    case triage
    /// Ready to be picked up.
    case todo
    /// All dependencies are met; ready for dispatch.
    case ready
    /// Currently being worked on.
    case running
    /// Blocked — waiting on external input.
    case blocked
    /// Under review.
    case review
    /// Completed successfully.
    case done
    /// Archived.
    case archived
}

/// A task on the kanban board.
///
/// Tasks are the unit of work in the kanban system. They have a status
/// lifecycle, an assignee, priority, and optional parent/child relationships
/// for dependency tracking.
public struct KanbanTask: Sendable, Codable, Identifiable {
    /// Unique identifier.
    public let id: String
    /// Short task title.
    public var title: String
    /// Full description / body.
    public var body: String
    /// Current status.
    public var status: TaskStatus
    /// Assigned profile name.
    public var assignee: String?
    /// Priority (higher = more urgent).
    public var priority: Int
    /// Parent task IDs (this task depends on these).
    public var parents: [String]
    /// Child task IDs (these depend on this task).
    public var children: [String]
    /// When the task was created.
    public let createdAt: Date
    /// When the task was last updated.
    public var updatedAt: Date
    /// Result summary, set on completion.
    public var result: String?
    /// Number of times this task has been retried.
    public var retryCount: Int

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String = "",
        status: TaskStatus = .todo,
        assignee: String? = nil,
        priority: Int = 0,
        parents: [String] = [],
        children: [String] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.parents = parents
        self.children = children
        self.createdAt = Date()
        self.updatedAt = Date()
        self.result = nil
        self.retryCount = 0
    }
}

/// Errors that can occur during kanban operations.
public enum KanbanError: Error, Sendable, CustomStringConvertible {
    case notFound(String)
    case invalidTransition(from: TaskStatus, to: TaskStatus)
    case cycleDetected
    case duplicateId(String)

    public var description: String {
        switch self {
        case .notFound(let id):
            return "Task '\(id)' not found."
        case .invalidTransition(let from, let to):
            return "Cannot transition from '\(from.rawValue)' to '\(to.rawValue)'."
        case .cycleDetected:
            return "Cannot create dependency cycle."
        case .duplicateId(let id):
            return "Task with id '\(id)' already exists."
        }
    }
}
