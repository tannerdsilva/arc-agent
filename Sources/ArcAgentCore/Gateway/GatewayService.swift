import Foundation
import AsyncHTTPClient
import ServiceLifecycle
import Logging

/// The top-level gateway service that manages the HTTP server, platform
/// adapters, session registry, and message routing.
///
/// ``GatewayService`` is a ``Service`` that composes:
/// - ``HTTPServerService`` — REST API endpoints + web UI
/// - ``WebSocketServerService`` — real-time WebSocket for the web UI
/// - ``TelegramAdapter`` — Telegram Bot API long polling
/// - ``SessionRegistry`` — active session agents (no cache, LMDB is source of truth)
/// - ``DeliveryManager`` — routes responses to the correct platform
/// - ``BotMessagingService`` — inter-agent messaging
/// - ``GroupChatManager`` — multi-agent coordination rooms
///
/// All components are managed by a ``ServiceGroup``.
public struct GatewayService: Service {

    private let httpServer: HTTPServerService
    private let wsServer: WebSocketServerService
    private let telegramAdapter: TelegramAdapter?
    private let registry: SessionRegistry
    private let deliveryManager: DeliveryManager
    private let botMessaging: BotMessagingService
    private let groupChatManager: GroupChatManager
    private let profileManager: ProfileManager
    private let logger: Logger

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        telegramToken: String? = nil,
        agentConfig: SessionRegistry.AgentConfig
    ) {
        let pm = ProfileManager()
        let dm = DeliveryManager()
        let bm = BotMessagingService(profileManager: pm)
        let gcm = GroupChatManager(profileManager: pm)
        let reg = SessionRegistry(
            agentConfig: agentConfig,
            deliveryManager: dm,
            profileManager: pm
        )
        let log = Logger(label: "com.arc-agent.gateway")

        self.profileManager = pm
        self.deliveryManager = dm
        self.botMessaging = bm
        self.groupChatManager = gcm
        self.registry = reg
        self.logger = log

        // Wire up the messaging service
        Task {
            await reg.setMessagingService(bm)
            await gcm.setMessagingService(bm)
        }

        // Create the WebSocket server on the next port
        let wsPort = port + 1
        self.wsServer = WebSocketServerService(
            host: host,
            port: wsPort,
            handlerFactory: { sessionID in
                WebSocketHandler(sessionID: sessionID)
            }
        )

        // Build the HTTP server with bot-mode web UI
        self.httpServer = HTTPServerService(
            config: .init(host: host, port: port),
            onChat: { [reg] sessionID, message in
                let handle = await reg.getOrCreate(sessionID: sessionID)
                let incoming = IncomingMessage(
                    id: UUID().uuidString,
                    chat: ChatTarget(platform: "api", chatID: sessionID),
                    text: message,
                    senderID: "api"
                )
                handle.inputContinuation.yield(incoming)
                // Await the agent's response from the response stream
                var responseText = ""
                for await response in handle.responses {
                    responseText = response
                    break  // Take the first response
                }
                return responseText.isEmpty ? "Message received" : responseText
            },
            onUI: { [pm, wsPort, host] in
                // Build the bot-mode web UI
                let profiles = (try? await pm.list()) ?? []
                let profileData = profiles.map { p in
                    ProfileData(
                        name: p.name,
                        title: p.title,
                        description: p.description,
                        avatarShape: p.avatar?.shape ?? "circle",
                        avatarColor: p.avatar?.color ?? "#8b5cf6",
                        avatarImage: p.avatar?.imageDataURL,
                        isActive: false,
                        isPinned: p.isPinned,
                        group: p.group
                    )
                }

                let botsPage = BotsPage(
                    profiles: profileData,
                    selectedBot: "default",
                    welcomeMessage: "Select a bot to start chatting, or create a new one."
                )

                let wsURL = "ws://\(host):\(wsPort)"
                let allStyles = CSSStylesheet(AppStyles.all + AppStyles.botStyles)
                let allScripts = Scripts.runtime + "\n" + Scripts.botMode

                let doc = HTMLDocument(
                    title: "ARC Agent — Bots",
                    body: botsPage.render(),
                    styles: allStyles,
                    scripts: allScripts,
                    wsURL: wsURL
                )
                return doc.render()
            }
        )

        // Set up Telegram adapter if token is provided
        if let token = telegramToken {
            self.telegramAdapter = TelegramAdapter(
                botToken: token,
                httpClient: HTTPClient(eventLoopGroupProvider: .singleton)
            )
        } else {
            self.telegramAdapter = nil
        }
    }

    // MARK: - Service

    public func run() async throws {
        logger.info("Starting ARC Agent Gateway (Bot Mode)...")

        var services: [any Service] = [httpServer, wsServer, botMessaging]
        if let telegram = telegramAdapter {
            services.append(telegram)
        }

        let serviceGroup = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: services,
                logger: logger
            )
        )

        try await serviceGroup.run()
    }
}
