import Foundation
import AsyncHTTPClient
import ServiceLifecycle
import Logging

/// A long-lived session agent Service managed by the gateway.
public actor SessionAgent: Service {

    public let sessionID: String
    public let profile: String

    private let agentConfig: SessionRegistry.AgentConfig
    private let profileManager: ProfileManager
    private let incomingMessages: AsyncStream<IncomingMessage>
    private let deliveryManager: DeliveryManager
    private let registry: SessionRegistry
    private let responseContinuation: AsyncStream<String>.Continuation
    private let logger = Logger(label: "com.arc-agent.session-agent")

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
                // Safe URL resolution — no force-unwrap
                if let profileURL = profileConfig.baseURL.flatMap({ URL(string: $0) }) {
                    resolvedBaseURL = profileURL
                } else if let configURL = URL(string: agentConfig.baseURL) {
                    resolvedBaseURL = configURL
                } else {
                    resolvedBaseURL = URL(string: "https://api.openai.com/v1")!
                }
                resolvedKey = agentConfig.apiKey
                resolvedSOUL = profileConfig.soulMD
                resolvedToolsets = (profileConfig.enabledToolsets, profileConfig.disabledToolsets)
            } else {
                resolvedModel = agentConfig.model
                resolvedProvider = agentConfig.provider
                if let url = URL(string: agentConfig.baseURL) {
                    resolvedBaseURL = url
                } else {
                    resolvedBaseURL = URL(string: "https://api.openai.com/v1")!
                }
                resolvedKey = agentConfig.apiKey
                resolvedSOUL = nil
                resolvedToolsets = (nil, nil)
            }

            // Build the agent with profile-specific configuration
            logger.info("step: opening LMDB session")
            let sessionEnv = try LMDBManager.openSession(sessionID)
            defer { LMDB.envClose(sessionEnv) }

            logger.info("step: building tool registry")
            let toolRegistry = try ArcAgentCore.buildDefaultRegistry()

            logger.info("step: creating ArcAgent")
            let agent = ArcAgent(config: ArcAgent.Configuration(
                model: resolvedModel,
                provider: resolvedProvider,
                baseURL: resolvedBaseURL,
                apiKey: resolvedKey,
                registry: toolRegistry,
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
            logger.info("step: setting up client")
            await agent.setupClient(httpClient: httpClient)

            // Inject the SOUL.md as a system message if present
            logger.info("step: checking soul")
            if let soul = resolvedSOUL {
                await agent.injectSystemMessage(soul)
            }

            // Process incoming messages
            logger.info("step: entering message loop")
            for try await message in incomingMessages {
                logger.info("step: running conversation")
                let response = try await agent.runConversation(message: message.text)
                let outgoing = OutgoingMessage(text: response)

                // Send response through BOTH channels:
                // 1. Response continuation (for HTTP API callers awaiting the result)
                responseContinuation.yield(response)
                // 2. Delivery manager (for platform adapters like Telegram)
                try await deliveryManager.send(message: outgoing, to: message.chat)

                // Report activity for the \"active now\" strip
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
