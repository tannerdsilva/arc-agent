import Foundation

/// Manages the lifecycle of subagents spawned by the delegation system.
///
/// ``DelegationManager`` is an **actor** — all subagent state is serialized.
/// It tracks running, completed, failed, and cancelled subagents, and
/// supports steering (sending messages to running children).
///
/// ## Concurrency
///
/// Each subagent runs as an isolated ``Task``. The manager holds a reference
/// to the task handle for cancellation and steering. Subagents are limited
/// by ``maxChildren`` to prevent runaway delegation.
///
/// ## Law of the Land
///
/// - **First Law**: Subagents are ``Task`` instances on the cooperative pool.
///   No threads, no dispatch queues, no locks.
/// - **Second Law**: The delegation manager is a sub-component of the agent
///   ``Service``. It is not itself a ``Service`` — it is a resource managed
///   by the agent's lifecycle.
public actor DelegationManager {

    /// Maximum number of concurrent children.
    public let maxChildren: Int

    /// Active subagents keyed by ID.
    private var agents: [String: Subagent] = [:]

    /// Task handles for running subagents, keyed by ID.
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Create a delegation manager.
    ///
    /// - Parameter maxChildren: Maximum concurrent children. Default 10.
    public init(maxChildren: Int = 10) {
        self.maxChildren = maxChildren
    }

    // MARK: - Public API

    /// The current list of all subagents.
    public var allAgents: [Subagent] {
        agents.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Look up a subagent by ID.
    public func agent(id: String) -> Subagent? {
        agents[id]
    }

    /// Spawn a new subagent with the given goal and context.
    ///
    /// The subagent runs as an isolated Task that executes a simplified
    /// agent loop: build prompt → call LLM → return summary.
    ///
    /// - Parameters:
    ///   - goal: The goal for the subagent.
    ///   - context: Background context for the subagent.
    ///   - allowedToolsets: Toolsets the subagent may use.
    /// - Returns: The subagent's ID.
    /// - Throws: ``DelegationError.tooManyChildren`` if at capacity.
    @discardableResult
    public func spawn(
        goal: String,
        context: String = "",
        allowedToolsets: [String] = []
    ) async throws -> String {
        guard agents.count < maxChildren else {
            throw DelegationError.tooManyChildren(max: maxChildren)
        }

        let agent = Subagent(
            goal: goal,
            context: context,
            allowedToolsets: allowedToolsets
        )
        let id = agent.id
        agents[id] = agent

        // Spawn the subagent as an isolated Task
        let task = Task { [weak self] in
            // Simulate work — in production this would call the LLM
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s placeholder
            await self?.complete(id: id, summary: "Completed: \(goal.prefix(80))")
        }
        tasks[id] = task

        return id
    }

    /// Send a message to a running subagent (steering).
    ///
    /// - Parameters:
    ///   - id: The subagent's ID.
    ///   - message: The message to send.
    /// - Throws: ``DelegationError.notFound`` or ``DelegationError.notSteerable``.
    public func steer(id: String, message: String) async throws {
        guard let agent = agents[id] else {
            throw DelegationError.notFound(id)
        }
        guard agent.status == .running else {
            throw DelegationError.notSteerable(id)
        }
        // In a full implementation, this would send the message to the
        // subagent's input stream. For now, log the steering attempt.
        agents[id]?.summary = "Steered: \(message)"
    }

    /// Cancel a running subagent.
    ///
    /// - Parameter id: The subagent's ID.
    /// - Throws: ``DelegationError.notFound``.
    public func cancel(id: String) async throws {
        guard agents[id] != nil else {
            throw DelegationError.notFound(id)
        }
        tasks[id]?.cancel()
        tasks[id] = nil
        agents[id]?.status = .cancelled
        agents[id]?.summary = "Cancelled by user."
    }

    /// Cancel all running subagents.
    public func cancelAll() async {
        for (id, task) in tasks {
            task.cancel()
            agents[id]?.status = .cancelled
            agents[id]?.summary = "Cancelled by user."
        }
        tasks.removeAll()
    }

    // MARK: - Internal

    /// Mark a subagent as completed with a summary.
    fileprivate func complete(id: String, summary: String) async {
        agents[id]?.status = .completed
        agents[id]?.summary = summary
        tasks[id] = nil
    }

    /// Mark a subagent as failed with an error.
    fileprivate func fail(id: String, error: String) async {
        agents[id]?.status = .failed
        agents[id]?.errorMessage = error
        tasks[id] = nil
    }
}
