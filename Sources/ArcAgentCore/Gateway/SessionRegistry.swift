import Foundation
import AsyncHTTPClient
import ServiceLifecycle
import Logging

/// A handle for communicating with a session agent.
///
/// Bundles the input continuation (for sending messages to the agent)
/// and the output stream (for receiving responses from the agent).
public struct SessionHandle: Sendable {
    /// Continuation for sending incoming messages to the agent.
    public let inputContinuation: AsyncStream<IncomingMessage>.Continuation
    /// Stream of response texts from the agent.
    public let responses: AsyncStream<String>
    /// Continuation for producing responses.
    public let responseContinuation: AsyncStream<String>.Continuation

    public init(
        inputContinuation: AsyncStream<IncomingMessage>.Continuation,
        responses: AsyncStream<String>,
        responseContinuation: AsyncStream<String>.Continuation
    ) {
        self.inputContinuation = inputContinuation
        self.responses = responses
        self.responseContinuation = responseContinuation
    }
}

/// A registry of active session agents managed by the gateway.
///
/// The registry is a routing table that maps session IDs to running
/// ``SessionAgent`` Services. It is NOT a cache — the agents are live
/// Services managed by the Service Lifecycle framework. Tessera is the
/// single source of truth for all durable data.
///
/// ## Profile-Aware Sessions
///
/// Each session is associated with a profile (bot). When a message arrives
/// for a session, the registry looks up the profile and creates an agent
/// with the profile's configuration (model, provider, toolsets, SOUL.md).
///
/// ## Law of the Land
///
/// - **First Law**: ``SessionRegistry`` is an actor — all mutable state is
///   guarded by the actor's serial executor.
public actor SessionRegistry {

    /// A factory that creates a new agent for a session.
    public struct AgentConfig: Sendable {
        public let model: String
        public let provider: String
        public let baseURL: String
        public let apiKey: String
        /// Tessera storage configuration. When set, sessions and memory are
        /// persisted to the Tessera server instead of local files.
        public let tessera: TesseraConfig?
        /// Whether session transcripts should be persisted each turn (only
        /// applies when `tessera` is set).
        public let persistSessions: Bool

        public init(
            model: String,
            provider: String,
            baseURL: String,
            apiKey: String,
            tessera: TesseraConfig? = nil,
            persistSessions: Bool = true
        ) {
            self.model = model
            self.provider = provider
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.tessera = tessera
            self.persistSessions = persistSessions
        }
    }

    private var agents: [String: SessionAgent] = [:]
    private var handles: [String: SessionHandle] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Consecutive crash count per session (used by auto-restart supervision).
    private var crashCounts: [String: Int] = [:]
    /// The profile each session's agents run under (needed to respawn).
    private var sessionProfiles: [String: String] = [:]
    /// Pending auto-restart tasks per session.
    private var respawnTasks: [String: Task<Void, Never>] = [:]
    private let agentConfig: AgentConfig
    private let deliveryManager: DeliveryManager
    private let profileManager: ProfileManager
    private(set) var messagingService: BotMessagingService?
    private let logger = Logger(label: "com.arc-agent.session-registry")

    /// Delay before the first auto-restart of a crashed session agent, in
    /// nanoseconds. Each further crash doubles it (exponential backoff).
    public var restartDelay: UInt64

    public init(
        agentConfig: AgentConfig,
        deliveryManager: DeliveryManager,
        profileManager: ProfileManager,
        restartDelay: UInt64 = 1_000_000_000
    ) {
        self.agentConfig = agentConfig
        self.deliveryManager = deliveryManager
        self.profileManager = profileManager
        self.restartDelay = restartDelay
    }

    /// Max consecutive crashes before the registry stops auto-restarting a
    /// session and leaves it dead until the next explicit ``getOrCreate``.
    static let maxSessionRestarts = 3

    /// Backoff for the Nth consecutive crash: delay * 2^(N-1), capped at
    /// delay * 8 so a crash loop never grows unbounded.
    static func respawnDelay(for attempt: Int, base: UInt64 = 1_000_000_000) -> UInt64 {
        base * UInt64(1 << min(max(attempt - 1, 0), 3))
    }

    /// Set the messaging service reference.
    func setMessagingService(_ service: BotMessagingService) {
        self.messagingService = service
    }

    /// Get or create a session agent for the given session ID.
    /// Returns a ``SessionHandle`` for bidirectional communication.
    ///
    /// Session generations are **sequential**: when a session already has a
    /// running agent, its input stream is finished and the caller waits for
    /// that generation to fully tear down (releasing its LMDB environment and
    /// HTTP client) before the successor starts. A successor therefore never
    /// contends with its predecessor for the session's LMDB environment, and
    /// there is no window in which ``removeIfCurrent(sessionID:agent:)`` can
    /// resolve against the wrong generation.
    func getOrCreate(sessionID: String, profile: String = "default") async -> SessionHandle {
        if let existing = agents[sessionID] {
            handles[sessionID]?.inputContinuation.finish()
            handles[sessionID]?.responseContinuation.finish()
            // Wait for the previous generation to exit and release the
            // session's resources before starting the successor.
            if let oldTask = tasks[sessionID] {
                await oldTask.value
            }
            tasks.removeValue(forKey: sessionID)
        } else {
            // The session is vacant (new or left dead after a crash loop):
            // drop any pending auto-restart; this explicit request is the
            // recovery.
            respawnTasks[sessionID]?.cancel()
            respawnTasks.removeValue(forKey: sessionID)
        }

        // Every explicit message resets the crash budget: each turn is a
        // fresh chance for the session agent.
        crashCounts[sessionID] = 0
        sessionProfiles[sessionID] = profile

        let (inputStream, inputContinuation) = AsyncStream<IncomingMessage>.makeStream()
        let (responseStream, responseContinuation) = AsyncStream<String>.makeStream()

        let handle = SessionHandle(
            inputContinuation: inputContinuation,
            responses: responseStream,
            responseContinuation: responseContinuation
        )

        let agent = SessionAgent(
            sessionID: sessionID,
            profile: profile,
            agentConfig: agentConfig,
            profileManager: profileManager,
            incomingMessages: inputStream,
            deliveryManager: deliveryManager,
            registry: self,
            responseContinuation: responseContinuation
        )
        agents[sessionID] = agent
        handles[sessionID] = handle

        // Start the agent loop in a detached task. The task is retained so a
        // superseding getOrCreate can await this generation's completion, and
        // so a crash can be supervised via `handleAgentCrash`.
        let task: Task<Void, Never> = Task {
            do {
                try await agent.run()
            } catch {
                logger.error("SessionAgent for \(sessionID) crashed: \(error)")
                // Supervise: identity-aware removal + bounded auto-restart.
                // If this agent was already superseded by a newer
                // getOrCreate, its crash must not disturb the successor.
                await self.handleAgentCrash(sessionID: sessionID, agent: agent)
            }
        }
        tasks[sessionID] = task

        return handle
    }

    /// Remove a session agent from the registry (called by the agent on shutdown).
    func remove(sessionID: String) {
        agents.removeValue(forKey: sessionID)
        handles[sessionID]?.inputContinuation.finish()
        handles[sessionID]?.responseContinuation.finish()
        handles.removeValue(forKey: sessionID)
        tasks.removeValue(forKey: sessionID)
        cancelPendingRestart(sessionID)
        crashCounts.removeValue(forKey: sessionID)
    }

    /// Remove the session agent **only if it is still the registered one**.
    ///
    /// ``getOrCreate(sessionID:profile:)`` replaces the handle+agent for a
    /// session on every message and finishes the previous agent's input
    /// stream. A superseded agent then exits its message loop and calls
    /// back into the registry to clean up — but the registry now points at
    /// the *new* agent's handle. An identity-blind removal would tear down
    /// the successor (finish its response stream, delete its handle), so
    /// the successor's response is lost and the caller sees "no response".
    /// This guard makes self-removal safe: a stale agent is a no-op, the
    /// current agent cleans itself up as before.
    @discardableResult
    func removeIfCurrent(sessionID: String, agent: SessionAgent) -> Bool {
        guard let registered = agents[sessionID], registered === agent else {
            return false
        }
        agents.removeValue(forKey: sessionID)
        handles[sessionID]?.inputContinuation.finish()
        handles[sessionID]?.responseContinuation.finish()
        handles.removeValue(forKey: sessionID)
        tasks.removeValue(forKey: sessionID)
        cancelPendingRestart(sessionID)
        return true
    }

    // MARK: - Crash Supervision

    /// Handle a session agent crash: remove it from the registry (identity
    /// aware), and schedule a bounded, backoff-restrained auto-restart so the
    /// session stays live through transient failures.
    ///
    /// A crash from a **superseded** generation is a no-op — the successor is
    /// left untouched. Consecutive crashes beyond ``maxSessionRestarts`` give
    /// up and leave the session dead until a new ``getOrCreate``. Each
    /// explicit message resets the budget, so a user turn is always a fresh
    /// chance.
    func handleAgentCrash(sessionID: String, agent: SessionAgent) async {
        guard agents[sessionID] === agent else {
            // Superseded (newer getOrCreate) or already handled — nothing to
            // do; the successor owns the session.
            return
        }
        let attempt = (crashCounts[sessionID] ?? 0) + 1
        crashCounts[sessionID] = attempt

        _ = removeIfCurrent(sessionID: sessionID, agent: agent)

        guard attempt <= Self.maxSessionRestarts else {
            logger.error(
                "SessionAgent for \(sessionID) crashed \(attempt) time(s); giving up on auto-restart until an explicit message")
            return
        }

        let profile = sessionProfiles[sessionID] ?? "default"
        let delay = Self.respawnDelay(for: attempt, base: restartDelay)
        logger.warning(
            "SessionAgent for \(sessionID) crashed (attempt \(attempt)); restarting in \(Double(delay) / 1_000_000_000)s")

        let task: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: delay)
            await self.respawnIfVacant(sessionID: sessionID, profile: profile)
        }
        respawnTasks[sessionID] = task
    }

    /// Restart a crashed session agent **only if the session is still
    /// vacant**. If a user message or a newer generation arrived while the
    /// backoff was sleeping, the explicit request is the recovery and this
    /// auto-restart is a no-op.
    func respawnIfVacant(sessionID: String, profile: String) async {
        defer { respawnTasks.removeValue(forKey: sessionID) }
        guard !Task.isCancelled, agents[sessionID] == nil else { return }
        logger.info("Restarting session agent for \(sessionID)")
        _ = await getOrCreate(sessionID: sessionID, profile: profile)
    }

    /// Cancel and drop any pending auto-restart for a session.
    private func cancelPendingRestart(_ sessionID: String) {
        respawnTasks[sessionID]?.cancel()
        respawnTasks.removeValue(forKey: sessionID)
    }

    // MARK: - Introspection (tests + gateway)

    /// The agent currently registered for a session, if any.
    func agent(for sessionID: String) -> SessionAgent? {
        agents[sessionID]
    }

    /// The consecutive-crash count for a session (used by supervision).
    func crashCount(for sessionID: String) -> Int? {
        crashCounts[sessionID]
    }

    /// The number of active session agents.
    var activeCount: Int { agents.count }
}
