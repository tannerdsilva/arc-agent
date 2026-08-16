import Foundation
import AsyncHTTPClient
import ServiceLifecycle

/// A long-lived session agent Service managed by the gateway.
///
/// Each ``SessionAgent`` runs for the lifetime of a single chat session.
/// It receives incoming messages via an ``AsyncStream``, processes them
/// through the agent loop, and sends responses back through the
/// ``DeliveryManager``.
///
/// When idle (no messages arrive), the Service Lifecycle framework
/// cancels the agent's Task, the cleanup blocks run, and the agent
/// removes itself from the ``SessionRegistry``.
public actor SessionAgent: Service {

    public let sessionID: String

    private let agentConfig: SessionRegistry.AgentConfig
    private let incomingMessages: AsyncStream<IncomingMessage>
    private let deliveryManager: DeliveryManager
    private let registry: SessionRegistry

    public init(
        sessionID: String,
        agentConfig: SessionRegistry.AgentConfig,
        incomingMessages: AsyncStream<IncomingMessage>,
        deliveryManager: DeliveryManager,
        registry: SessionRegistry
    ) {
        self.sessionID = sessionID
        self.agentConfig = agentConfig
        self.incomingMessages = incomingMessages
        self.deliveryManager = deliveryManager
        self.registry = registry
    }

    // MARK: - Service

    public func run() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        do {
            let agent = ArcAgent(config: ArcAgent.Configuration(
                model: agentConfig.model,
                provider: agentConfig.provider,
                baseURL: URL(string: agentConfig.baseURL)!,
                apiKey: agentConfig.apiKey,
                registry: try ArcAgentCore.buildDefaultRegistry(),
                sessionStore: LMDBSessionStore(),
                memoryProvider: LMDBMemoryProvider(),
                skills: [],
                maxIterations: 25,
                maxTurnDuration: 120,
                persistSessions: true,
                approvalMode: .manual,
                query: nil,
                maxContextTokens: 64_000
            ))
            await agent.setupClient(httpClient: httpClient)

            for try await message in incomingMessages {
                let response = try await agent.runConversation(message: message.text)
                let outgoing = OutgoingMessage(text: response)
                try await deliveryManager.send(message: outgoing, to: message.chat)
            }
        } catch {
            try? await httpClient.shutdown()
            await registry.remove(sessionID: sessionID)
            throw error
        }

        try? await httpClient.shutdown()
        await registry.remove(sessionID: sessionID)
    }
}
