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
            let resolvedContext: ProfileContextConfig?

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
                resolvedContext = profileConfig.context
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
                resolvedContext = nil
            }

            // Storage backend. When Tessera is configured, sessions and
            // memory flow through the shared Tessera connection (signed
            // NOSTR events). Without it we fall back to local files so the
            // gateway can still run without a server.
            logger.info("step: opening session storage")
            let sessionStore: any SessionStore
            let memoryProvider: any MemoryProvider
            if let tessera = agentConfig.tessera {
                await TesseraConnection.shared.configure(tessera)
                sessionStore = TesseraSessionStore()
                memoryProvider = TesseraMemoryProvider()
            } else {
                sessionStore = FileSessionStore()
                memoryProvider = FileMemoryProvider()
            }

            logger.info("step: building tool registry")
            let toolRegistry = try await MutableToolRegistry.make(enabledPlugins: pluginAllowList())

            logger.info("step: creating ArcAgent")
            let agent = ArcAgent(config: ArcAgent.Configuration(
                model: resolvedModel,
                provider: resolvedProvider,
                baseURL: resolvedBaseURL,
                apiKey: agentConfig.apiKey,
                registry: toolRegistry,
                sessionStore: sessionStore,
                memoryProvider: memoryProvider,
                skills: [],
                maxIterations: agentConfig.maxIterations ?? 25,
                toolLoopCap: agentConfig.toolLoopCap,
                maxTurnDuration: 120,
                persistSessions: agentConfig.tessera != nil ? agentConfig.persistSessions : false,
                approvalMode: .manual,
                query: nil,
                maxContextTokens: 64_000,
                sessionID: sessionID,
                contextLength: resolvedContext?.contextLength,
                platformHint: "gateway",
                moa: agentConfig.moa,
                reasoningEffort: resolvedContext?.reasoningEffort,
                temperature: resolvedContext?.temperature,
                topP: resolvedContext?.topP,
                maxOutputTokens: resolvedContext?.maxOutputTokens,
                mcpServers: agentConfig.mcpServers
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
                let chat = message.chat

                // Live streaming delivery (Hermes parity): typing indicator +
                // in-place edits while the agent streams, final edit/send at end.
                var editable = await deliveryManager.canEdit(to: chat)
                var buffer = ""
                var latestID: String? = nil
                var lastEditAt = Date.distantPast
                let typingTask = Task {
                    while !Task.isCancelled {
                        try? await deliveryManager.sendTyping(to: chat)
                        try? await Task.sleep(for: .seconds(3.5))
                    }
                }
                var streamError: Error? = nil
                do {
                    let stream = agent.streamConversation(message: message.text)
                    for try await delta in stream {
                        buffer += delta
                        if editable, let id = latestID,
                           Date().timeIntervalSince(lastEditAt) > 0.8 {
                            do {
                                try await deliveryManager.update(
                                    messageID: id, text: buffer, parseMode: nil, to: chat
                                )
                                lastEditAt = Date()
                            } catch {
                                // Adapter rejects in-place edits (too long,
                                // unsupported) — drop the partial and fall
                                // back to send-once at the end.
                                logger.notice("gateway: edit fell back: \(error)")
                                if let id = latestID {
                                    try? await deliveryManager.delete(messageID: id, to: chat)
                                }
                                latestID = nil
                                editable = false
                            }
                        } else if editable, latestID == nil {
                            // First delta becomes the initial message to edit.
                            let result = try await deliveryManager.send(
                                message: OutgoingMessage(text: buffer, isPartial: true), to: chat
                            )
                            latestID = result.messageID
                            lastEditAt = Date()
                        }
                    }
                } catch {
                    streamError = error
                }
                typingTask.cancel()

                let finalText = buffer
                do {
                    if let error = streamError { throw error }
                    if editable, let id = latestID, finalText.count <= 4096 {
                        try await deliveryManager.update(
                            messageID: id, text: finalText, parseMode: nil, to: chat
                        )
                    } else {
                        // Email threading metadata from the inbound message
                        // (subject / In-Reply-To / References) rides along on
                        // final delivery so replies continue the thread.
                        let meta = emailMetadata(for: message)
                        let result = try await deliveryManager.send(
                            message: OutgoingMessage(text: finalText, metadata: meta), to: chat
                        )
                        latestID = result.messageID
                    }
                } catch {
                    logger.error("gateway: delivery failed for \(chat.platform): \(error)")
                }

                // Send response through BOTH channels:
                // 1. Response continuation (for HTTP API callers awaiting the result)
                responseContinuation.yield(finalText)
                // 2. Delivery manager (for platform adapters like Telegram)

                // Report activity for the \"active now\" strip
                if let messaging = await registry.messagingService {
                    await messaging.reportActivity(profile: profile, kind: .turnCompleted)
                }
            }
        } catch {
            try? await httpClient.shutdown()
            responseContinuation.finish()
            // Supervise the crash: identity-aware removal plus a bounded
            // auto-restart by the registry (keeps the session live through
            // transient failures). A superseded generation's crash is a no-op.
            await registry.handleAgentCrash(sessionID: sessionID, agent: self)
            throw error
        }

        try? await httpClient.shutdown()
        responseContinuation.finish()
        await registry.removeIfCurrent(sessionID: sessionID, agent: self)
    }

    /// Extract email reply-threading metadata carried on the inbound message.
    private nonisolated func emailMetadata(for message: IncomingMessage) -> [String: String]? {
        guard message.chat.platform == "email",
              let raw = message.raw,
              let subject = raw["emailSubject"]?.value as? String else { return nil }
        return [
            "subject": subject,
            "inReplyTo": (raw["emailMessageID"]?.value as? String) ?? "",
            "references": (raw["emailReferences"]?.value as? String) ?? "",
        ]
    }
}
