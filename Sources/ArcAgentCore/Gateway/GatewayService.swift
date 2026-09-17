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
    private let profileRoutes: [ProfileRoute]
    private let multiplexProfiles: Bool

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        telegramToken: String? = nil,
        agentConfig: SessionRegistry.AgentConfig,
        profileRouting: ProfileRoutingConfig = ProfileRoutingConfig()
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
        self.profileRoutes = profileRouting.sortedRoutes
        self.multiplexProfiles = profileRouting.multiplexProfiles

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
            registry: reg,
            handlerFactory: { sessionID, registry in
                WebSocketHandler(sessionID: sessionID, registry: registry)
            }
        )

        // Build the HTTP server with bot-mode web UI
        self.httpServer = HTTPServerService(
            config: .init(host: host, port: port),
            onChat: { [reg, routes = profileRouting.sortedRoutes, multiplex = profileRouting.multiplexProfiles] sessionID, message in
                let chat = ChatTarget(platform: "api", chatID: sessionID)
                let profile = ProfileRouteResolver.profile(
                    for: chat, routes: routes, multiplexProfiles: multiplex
                ) ?? "default"
                let handle = await reg.getOrCreate(sessionID: sessionID, profile: profile)
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
            onUI: { [pm, wsPort, host] mode in
                // Build the web UI based on mode
                let wsURL = "ws://\(host):\(wsPort)"
                let allStyles: CSSStylesheet
                let allScripts: String
                let body: String
                let title: String
                let settingsHTML: String
#if DEBUG
                let devMode = true
#else
                let devMode = false
#endif

                if mode == "bots" {
                    // Bot mode: show the full bots page
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

                    allStyles = CSSStylesheet(AppStyles.all + AppStyles.botStyles)
                    allScripts = Scripts.runtime + "\n" + Scripts.botMode
                    body = botsPage.render()
                    title = "ARC Agent — Bots"
                    // Bot mode has its own settings entry point (/ui/settings).
                    settingsHTML = ""
                } else if mode == "settings" {
                    // Settings page
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

                    let settingsPage = SettingsPage(
                        profiles: profileData,
                        selectedBot: "default"
                    )

                    allStyles = CSSStylesheet(AppStyles.all + AppStyles.botStyles)
                    allScripts = Scripts.runtime + "\n" + Scripts.botMode
                    body = settingsPage.render()
                    title = "ARC Agent — Settings"
                    // The settings page IS the settings surface.
                    settingsHTML = ""
                } else {
                    // Chat mode: show the clean chat interface
                    let chatPage = ChatPage(
                        welcomeMessage: "How can I help you today?",
                        modelName: "default",
                        models: [],
                        activeMode: "chat"
                    )

                    allStyles = CSSStylesheet(AppStyles.all)
                    allScripts = Scripts.runtime
                    body = chatPage.render()
                    title = "ARC Agent"
                    // The chat header's gear button toggles this overlay.
                    settingsHTML = SettingsPanel(isOpen: false).render()
                }

                let doc = HTMLDocument(
                    title: title,
                    body: body,
                    styles: allStyles,
                    scripts: allScripts,
                    wsURL: wsURL,
                    settingsHTML: settingsHTML,
                    devMode: devMode
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
            // Ingest platform messages into sessions, routing each to the
            // profile its route table specifies (default when unmatched).
            // Same consumption pattern as the HTTP path; the task's lifetime
            // is bounded by the adapter's AsyncStream (see
            // TelegramAdapter.incomingMessages).
            Task {
                for await incoming in telegram.incomingMessages {
                    let profile = ProfileRouteResolver.profile(
                        for: incoming.chat,
                        routes: self.profileRoutes,
                        multiplexProfiles: self.multiplexProfiles
                    ) ?? "default"
                    let sessionID = "\(incoming.chat.platform):\(incoming.chat.chatID):\(incoming.chat.threadID ?? "")"
                    let handle = await self.registry.getOrCreate(sessionID: sessionID, profile: profile)
                    handle.inputContinuation.yield(incoming)
                }
            }
        }

        let serviceGroup = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: services,
                logger: logger
            )
        )

        do {
            try await serviceGroup.run()
        } catch {
            // Release the shared Tessera connection (WireGuard tunnel) at
            // teardown.
            await TesseraConnection.shared.shutdown()
            throw error
        }
        // Release the shared Tessera connection (WireGuard tunnel) at
        // teardown.
        await TesseraConnection.shared.shutdown()
    }
}
