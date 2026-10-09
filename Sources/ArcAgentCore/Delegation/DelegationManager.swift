import Foundation
import Logging

/// Manages the lifecycle of subagents spawned by the delegation system.
///
/// ``DelegationManager`` is an **actor** — all subagent state is serialized.
/// It tracks running, completed, failed, and cancelled subagents, and
/// supports steering (sending messages to running children).
///
/// ## Concurrency
///
/// Each subagent is a real ``ArcAgent`` child running as an isolated
/// ``Task`` on the cooperative pool (First Law). The manager holds the task
/// handle for cancellation and steering. Subagents are limited by
/// ``maxChildren`` to prevent runaway delegation.
///
/// ## Child isolation
///
/// Children get a fresh context (no parent history), a focused prompt built
/// from goal + context, a filtered tool registry (toolset intersection, with
/// the `delegation` toolset always removed — no recursive delegation), a
/// volatile in-memory session store, and no memory/skills injection. The
/// child's final answer is returned verbatim as the subagent summary.
///
/// ## Law of the Land
///
/// - **First Law**: Subagents are ``Task`` instances on the cooperative pool.
///   No threads, no dispatch queues, no locks.
/// - **Second Law**: The delegation manager is a sub-component of the agent
///   ``Service``. It is not itself a ``Service`` — it is a resource managed
///   by the agent's lifecycle.
public actor DelegationManager {

    /// The toolset that is always stripped from children (no recursion).
    public static let blockedToolsets: Set<String> = ["delegation"]

    /// Maximum number of concurrent children.
    public let maxChildren: Int

    /// Parent configuration cloned for each child (nil = spawn not available).
    private let parentConfiguration: ArcAgent.Configuration?

    /// Per-child iteration budget.
    private let childMaxTurns: Int

    /// Wall-clock budget for a child, in seconds.
    private let childTimeout: Int

    /// Active subagents keyed by ID.
    private var agents: [String: Subagent] = [:]

    /// Task handles for running subagents, keyed by ID.
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Running child agents keyed by ID (steering/cancellation targets).
    private var children: [String: ArcAgent] = [:]

    /// Result streams handed to callers (the delegate_task tool).
    private var streams: [String: AsyncThrowingStream<String, Error>] = [:]

    /// Continuations for the result streams.
    private var continuations: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]

    /// Create a delegation manager.
    ///
    /// - Parameters:
    ///   - maxChildren: Maximum concurrent children. Default 10.
    ///   - parentConfiguration: The orchestrator's configuration, cloned for
    ///     children (model, credentials, registry, toolset filters). Nil
    ///     disables spawning with ``DelegationError/notConfigured``.
    ///   - childMaxTurns: Per-child iteration budget.
    ///   - childTimeout: Per-child wall-clock budget in seconds.
    public init(
        maxChildren: Int = 10,
        parentConfiguration: ArcAgent.Configuration? = nil,
        childMaxTurns: Int = 25,
        childTimeout: Int = 600
    ) {
        self.maxChildren = maxChildren
        self.parentConfiguration = parentConfiguration
        self.childMaxTurns = childMaxTurns
        self.childTimeout = childTimeout
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

    /// The result stream for a spawned child (yields the summary, then ends).
    public func stream(id: String) -> AsyncThrowingStream<String, Error>? {
        streams[id]
    }

    /// Spawn a new subagent with the given goal and context.
    ///
    /// The subagent runs as an isolated ``ArcAgent`` Task child (own
    /// context, filtered tool registry, focused goal prompt) and yields its
    /// final answer through ``stream(id:)`` when done.
    ///
    /// - Parameters:
    ///   - goal: The goal for the subagent.
    ///   - context: Background context for the subagent.
    ///   - allowedToolsets: Toolsets the subagent may use. Empty = inherit
    ///     all of the parent's toolsets (the delegation toolset is always
    ///     excluded).
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
        guard let parent = parentConfiguration else {
            throw DelegationError.notConfigured
        }

        let agent = Subagent(
            goal: goal,
            context: context,
            allowedToolsets: allowedToolsets
        )
        let id = agent.id
        agents[id] = agent

        var stream: AsyncThrowingStream<String, Error>!
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        let made = AsyncThrowingStream.makeStream(of: String.self)
        stream = made.stream
        continuation = made.continuation
        streams[id] = stream
        continuations[id] = continuation

        let childConfig = Self.makeChildConfiguration(
            parent: parent,
            goal: goal,
            context: context,
            allowedToolsets: allowedToolsets,
            maxTurns: childMaxTurns
        )
        let timeout = childTimeout

        // Spawn the subagent as an isolated Task (First Law). The child is a
        // real ArcAgent: it primes its own client, runs its turn loop with
        // the filtered registry, and returns its final answer.
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let child = ArcAgent(config: childConfig)
                await self.registerChild(id: id, child: child)
                let summary = try await self.runChild(
                    child: child,
                    goal: goal,
                    context: context,
                    timeout: timeout
                )
                await self.complete(id: id, summary: summary)
            } catch is CancellationError {
                await self.fail(id: id, error: "Cancelled.")
            } catch {
                await self.fail(id: id, error: String(describing: error))
            }
            await self.finishChild(id: id)
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
        // Deliver to the child's mid-turn steer channel; it is drained before
        // the child's next LLM request (same mechanism as the REPL /steer).
        if let child = children[id] {
            await child.steer(message)
        } else {
            // Child Task not registered yet: park it so spawn can deliver.
            pendingSteers[id, default: []].append(message)
        }
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
        await children[id]?.interruptTurn()
        tasks[id] = nil
        agents[id]?.status = .cancelled
        agents[id]?.summary = "Cancelled by user."
        await finishStream(id: id, summary: "Cancelled by user.")
    }

    /// Cancel all running subagents.
    public func cancelAll() async {
        for (id, task) in tasks {
            task.cancel()
            await children[id]?.interruptTurn()
            agents[id]?.status = .cancelled
            agents[id]?.summary = "Cancelled by user."
            await finishStream(id: id, summary: "Cancelled by user.")
        }
        tasks.removeAll()
    }

    // MARK: - Internal

    /// Late steers for children that have not registered yet.
    private var pendingSteers: [String: [String]] = [:]

    fileprivate func registerChild(id: String, child: ArcAgent) async {
        children[id] = child
        if let queued = pendingSteers.removeValue(forKey: id) {
            for message in queued {
                await child.steer(message)
            }
        }
    }

    /// Run the child with a bounded wall clock (structured race, First Law).
    private func runChild(
        child: ArcAgent,
        goal: String,
        context: String,
        timeout: Int
    ) async throws -> String {
        let prompt = Self.makeChildPrompt(goal: goal, context: context)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await child.runOneShot(query: prompt)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                throw DelegationError.timeout(seconds: timeout)
            }
            guard let first = try await group.next() else {
                throw DelegationError.timeout(seconds: timeout)
            }
            group.cancelAll()
            return first
        }
    }

    /// Mark a subagent as completed with a summary.
    fileprivate func complete(id: String, summary: String) async {
        guard agents[id]?.status != .cancelled else { return }
        agents[id]?.status = .completed
        agents[id]?.summary = summary
        tasks[id] = nil
        await finishStream(id: id, summary: summary)
    }

    /// Mark a subagent as failed with an error.
    fileprivate func fail(id: String, error: String) async {
        guard agents[id]?.status != .cancelled else { return }
        agents[id]?.status = .failed
        agents[id]?.errorMessage = error
        tasks[id] = nil
        await finishStream(id: id, summary: "Task failed: \(error)")
    }

    private func finishChild(id: String) async {
        await children[id]?.shutdownHTTPClient()
        children[id] = nil
    }

    private func finishStream(id: String, summary: String) async {
        continuations[id]?.yield(summary)
        continuations[id]?.finish()
        continuations[id] = nil
        streams[id] = nil
    }

    // MARK: - Child configuration

    /// Clone the parent configuration into a child config.
    ///
    /// - `allowedToolsets` empty = inherit all parent toolsets; otherwise the
    ///   intersection with the parent's toolsets.
    /// - The `delegation` toolset is always stripped (no recursive
    ///   delegation, which also bounds spawn depth).
    /// - Children get a volatile store, no memory/skills, a bounded iteration
    ///   budget, and no approval prompts (the orchestrator already made the
    ///   delegation decision).
    static func makeChildConfiguration(
        parent: ArcAgent.Configuration,
        goal: String,
        context: String,
        allowedToolsets: [String],
        maxTurns: Int
    ) -> ArcAgent.Configuration {
        let parentToolsets = Set(parent.registry.allTools.map(\.toolset))
        let desired = allowedToolsets.isEmpty
            ? parentToolsets
            : Set(allowedToolsets).intersection(parentToolsets)
        let disabled = parentToolsets.subtracting(desired)
            .union(Self.blockedToolsets)
            .union(parent.disabledToolsets)

        var cfg = parent
        cfg.disabledToolsets = disabled
        cfg.query = nil
        cfg.sessionID = UUID().uuidString
        cfg.sessionStore = VolatileSessionStore()
        cfg.persistSessions = false
        cfg.memoryProvider = nil
        cfg.skills = []
        cfg.maxIterations = maxTurns > 0 ? maxTurns : 25
        cfg.approvalMode = .off
        cfg.platformHint = "delegation"
        cfg.injectProjectContext = false
        cfg.contextDirectory = nil
        cfg.verifyOnStop = false
        cfg.backgroundReview = BackgroundReview.Settings()
        cfg.moa = MoAConfig()
        return cfg
    }

    /// The focused prompt delivered to a child: context + goal, no history.
    static func makeChildPrompt(goal: String, context: String) -> String {
        var prompt = "You are a focused subagent of a larger task. Work only on the assigned goal "
            + "and reply with your final result only — no questions, no commentary."
        if !context.isEmpty {
            prompt += "\n\nContext from the orchestrator:\n\(context)"
        }
        prompt += "\n\nGoal:\n\(goal)"
        return prompt
    }
}
