import Foundation

/// The status of a subagent.
public enum SubagentStatus: String, Sendable, Codable {
    /// The subagent is running.
    case running
    /// The subagent completed successfully.
    case completed
    /// The subagent failed with an error.
    case failed
    /// The subagent was cancelled.
    case cancelled
}

/// A subagent spawned by the delegation system.
///
/// Each subagent runs as an isolated async Task with its own tool registry
/// (filtered by toolset intersection) and returns a summary when done.
public struct Subagent: Sendable, Identifiable {
    /// Unique identifier for this subagent.
    public let id: String
    /// The goal or instruction given to the subagent.
    public let goal: String
    /// Context provided to the subagent.
    public let context: String
    /// When the subagent was created.
    public let createdAt: Date
    /// The current status.
    public var status: SubagentStatus
    /// The final summary, set when the subagent completes.
    public var summary: String?
    /// Any error message, set when the subagent fails.
    public var errorMessage: String?
    /// The toolsets the subagent is allowed to use.
    public let allowedToolsets: [String]

    public init(
        id: String = UUID().uuidString,
        goal: String,
        context: String = "",
        allowedToolsets: [String] = []
    ) {
        self.id = id
        self.goal = goal
        self.context = context
        self.createdAt = Date()
        self.status = .running
        self.summary = nil
        self.errorMessage = nil
        self.allowedToolsets = allowedToolsets
    }
}

/// Errors that can occur during delegation.
public enum DelegationError: Error, Sendable, CustomStringConvertible {
    /// The subagent was not found.
    case notFound(String)
    /// The subagent is not in a steerable state.
    case notSteerable(String)
    /// The subagent limit was reached.
    case tooManyChildren(max: Int)

    public var description: String {
        switch self {
        case .notFound(let id):
            return "Subagent '\(id)' not found."
        case .notSteerable(let id):
            return "Subagent '\(id)' is not steerable (status: not running)."
        case .tooManyChildren(let max):
            return "Maximum number of children (\(max)) reached."
        }
    }
}
