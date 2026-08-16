import Foundation
import AsyncHTTPClient
import ServiceLifecycle

/// A registry of active session agents managed by the gateway.
///
/// The registry is a routing table that maps session IDs to running
/// ``SessionAgent`` Services. It is NOT a cache — the agents are live
/// Services managed by the Service Lifecycle framework. LMDB is the
/// single source of truth for all durable data.
///
/// When a message arrives for a session that has no active agent, the
/// registry creates a new ``SessionAgent``, starts it as a Service, and
/// registers it. When the agent's `run()` completes (idle timeout or
/// cancellation), it removes itself from the registry.
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
    /// Continuations for sending messages to active session agents.
    private var continuations: [String: AsyncStream<IncomingMessage>.Continuation] = [:]
    private let agentConfig: AgentConfig
    private let deliveryManager: DeliveryManager

    public init(agentConfig: AgentConfig, deliveryManager: DeliveryManager) {
        self.agentConfig = agentConfig
        self.deliveryManager = deliveryManager
    }

    /// Get or create a session agent for the given session ID.
    /// Returns the continuation for sending messages to the agent.
    func getOrCreate(sessionID: String) -> AsyncStream<IncomingMessage>.Continuation {
        if let existing = continuations[sessionID] {
            return existing
        }

        let (stream, continuation) = AsyncStream<IncomingMessage>.makeStream()
        let agent = SessionAgent(
            sessionID: sessionID,
            agentConfig: agentConfig,
            incomingMessages: stream,
            deliveryManager: deliveryManager,
            registry: self
        )
        agents[sessionID] = agent
        continuations[sessionID] = continuation
        return continuation
    }

    /// Remove a session agent from the registry (called by the agent on shutdown).
    func remove(sessionID: String) {
        agents.removeValue(forKey: sessionID)
        continuations[sessionID]?.finish()
        continuations.removeValue(forKey: sessionID)
    }

    /// The number of active session agents.
    var activeCount: Int { agents.count }
}
