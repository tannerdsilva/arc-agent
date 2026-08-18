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
/// Services managed by the Service Lifecycle framework. LMDB is the
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

        public init(model: String, provider: String, baseURL: String, apiKey: String) {
            self.model = model
            self.provider = provider
            self.baseURL = baseURL
            self.apiKey = apiKey
        }
    }

    private var agents: [String: SessionAgent] = [:]
    private var handles: [String: SessionHandle] = [:]
    private let agentConfig: AgentConfig
    private let deliveryManager: DeliveryManager
    private let profileManager: ProfileManager
    private(set) var messagingService: BotMessagingService?
    private let logger = Logger(label: "com.arc-agent.session-registry")

    public init(
        agentConfig: AgentConfig,
        deliveryManager: DeliveryManager,
        profileManager: ProfileManager
    ) {
        self.agentConfig = agentConfig
        self.deliveryManager = deliveryManager
        self.profileManager = profileManager
    }

    /// Set the messaging service reference.
    func setMessagingService(_ service: BotMessagingService) {
        self.messagingService = service
    }

    /// Get or create a session agent for the given session ID.
    /// Returns a ``SessionHandle`` for bidirectional communication.
    func getOrCreate(sessionID: String, profile: String = "default") -> SessionHandle {
        // Always create a fresh handle and agent for now.
        // Session reuse will be implemented when we have proper lifecycle management.
        if let existing = handles[sessionID] {
            existing.inputContinuation.finish()
            existing.responseContinuation.finish()
            handles.removeValue(forKey: sessionID)
            agents.removeValue(forKey: sessionID)
        }

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

        // Start the agent loop in a detached task
        Task {
            do {
                try await agent.run()
            } catch {
                logger.error("SessionAgent for \(sessionID) crashed: \(error)")
                // Clean up on crash. Identity-aware: if this agent was already
                // superseded by a newer getOrCreate, its teardown must not
                // tear down the successor's handle.
                await self.removeIfCurrent(sessionID: sessionID, agent: agent)
            }
        }

        return handle
    }

    /// Remove a session agent from the registry (called by the agent on shutdown).
    func remove(sessionID: String) {
        agents.removeValue(forKey: sessionID)
        handles[sessionID]?.inputContinuation.finish()
        handles[sessionID]?.responseContinuation.finish()
        handles.removeValue(forKey: sessionID)
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
        return true
    }

    /// The number of active session agents.
    var activeCount: Int { agents.count }
}
