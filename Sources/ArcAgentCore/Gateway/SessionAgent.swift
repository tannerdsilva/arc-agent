import Foundation
import AsyncHTTPClient
import ServiceLifecycle

/// A long-lived session agent Service managed by the gateway.
///
/// Each ``SessionAgent`` runs for the lifetime of a single chat session.
/// It receives incoming messages via an ``AsyncStream``, processes them
/// through the agent loop, and sends responses back through the
/// response continuation and ``DeliveryManager``.
///
/// ## Profile-Aware
///
/// Each session agent is associated with a **profile** (bot). The profile
/// determines the agent's model, provider, toolsets, SOUL.md personality,
/// and memory store. This is how Bot Mode works — each bot gets its own
/// isolated agent configuration.
///
/// ## Response Plumbing
///
/// The agent sends responses through TWO channels:
/// 1. The ``responseContinuation`` — for the HTTP API caller to await
/// 2. The ``DeliveryManager`` — for platform adapter delivery (Telegram, etc.)
///
/// When idle (no messages arrive), the Service Lifecycle framework
/// cancels the agent's Task, the cleanup blocks run, and the agent
/// removes itself from the ``SessionRegistry``.
public actor SessionAgent: Service {

    public let sessionID: String
    public let profile: String

    private let agentConfig: SessionRegistry.AgentConfig
    private let profileManager: ProfileManager
    private let incomingMessages: AsyncStream<IncomingMessage>
    private let deliveryManager: DeliveryManager
    private let registry: SessionRegistry
    private let responseContinuation: AsyncStream<String>.Continuation

    public init(
        sessionID: String,
        profile: String = "default",
        agentConfig: SessionRegistry.AgentConfig,
        profileManager: ProfileManager,
        incomingMessages: AsyncStream<IncomingMessage>,
        deliveryManager: DeliveryManager,
        registry: SessionRegistry,
        responseContinuation: AsyncStream<String>.Continuation
    ) {
        self.sessionID = sessionID
        self.profile = profile
        self.agentConfig = agentConfig
        self.profileManager = profileManager
        self.incomingMessages = incomingMessages
        self.deliveryManager = deliveryManager
        self.registry = registry
        self.responseContinuation = responseContinuation
    }

    // MARK: - Service

    public func run() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        do {
            // Resolve profile-specific configuration
            let resolvedModel: String
            let resolvedProvider: String
            let resolvedBaseURL: URL
            let resolvedKey: String
            let resolvedSOUL: String?
            let resolvedToolsets: (enabled: Set<String>?, disabled: Set<String>?)

            if let profileConfig = try await profileManager.get(name: profile) {
                resolvedModel = profileConfig.model ?? agentConfig.model
                resolvedProvider = profileConfig.provider ?? agentConfig.provider
                resolvedBaseURL = profileConfig.baseURL.flatMap { URL(string: $0) }
                    ?? URL(string: agentConfig.baseURL)!
                resolvedKey = agentConfig.apiKey
                resolvedSOUL = profileConfig.soulMD
                resolvedToolsets = (profileConfig.enabledToolsets, profileConfig.disabledToolsets)
            } else {
                resolvedModel = agentConfig.model
                resolvedProvider = agentConfig.provider
                resolvedBaseURL = URL(string: agentConfig.baseURL)!
                resolvedKey = agentConfig.apiKey
                resolvedSOUL = nil
                resolvedToolsets = (nil, nil)
            }

            // Build the agent with profile-specific configuration
            let sessionEnv = try LMDBManager.openSession(sessionID)
            defer { LMDB.envClose(sessionEnv) }

            let agent = ArcAgent(config: ArcAgent.Configuration(
                model: resolvedModel,
                provider: resolvedProvider,
                baseURL: resolvedBaseURL,
                apiKey: resolvedKey,
                registry: try ArcAgentCore.buildDefaultRegistry(),
                sessionStore: LMDBSessionStore(env: sessionEnv),
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

            // Inject the SOUL.md as a system message if present
            if let soul = resolvedSOUL {
                await agent.injectSystemMessage(soul)
            }

            // Process incoming messages
            for try await message in incomingMessages {
                let response = try await agent.runConversation(message: message.text)
                let outgoing = OutgoingMessage(text: response)

                // Send response through BOTH channels:
                // 1. Response continuation (for HTTP API callers awaiting the result)
                responseContinuation.yield(response)
                // 2. Delivery manager (for platform adapters like Telegram)
                try await deliveryManager.send(message: outgoing, to: message.chat)

                // Report activity for the "active now" strip
                if let messaging = await registry.messagingService {
                    await messaging.reportActivity(profile: profile, kind: .turnCompleted)
                }
            }
        } catch {
            try? await httpClient.shutdown()
            responseContinuation.finish()
            await registry.remove(sessionID: sessionID)
            throw error
        }

        try? await httpClient.shutdown()
        responseContinuation.finish()
        await registry.remove(sessionID: sessionID)
    }
}
