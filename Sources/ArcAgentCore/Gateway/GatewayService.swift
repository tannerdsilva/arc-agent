import Foundation
import AsyncHTTPClient
import ServiceLifecycle
import Logging
import NIO

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
    private let platformAdapters: [any PlatformAdapter]
    private let registry: SessionRegistry
    private let deliveryManager: DeliveryManager
    private let botMessaging: BotMessagingService
    private let groupChatManager: GroupChatManager
    private let profileManager: ProfileManager
    private let logger: Logger
    private let profileRoutes: [ProfileRoute]
    private let multiplexProfiles: Bool
    /// Shared adapter HTTP client (nil when no adapter needs one); shut down
    /// explicitly in `run()` on both success and failure — an unshutdown
    /// AsyncHTTPClient traps on deinit.
    private let httpClient: HTTPClient?
    /// Chat→session binding (Hermes `session_router` parity): resolves every
    /// incoming chat to its deterministic session ID.
    private let sessionRouter: SessionRouter
    /// Scheduled job runner (Hermes `cron` service parity): registered as a
    /// Service; the injected runner executes each due job as a one-shot agent
    /// session.
    private let cronScheduler: CronScheduler

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        telegramToken: String? = nil,
        gatewayConfig: GatewayConfig? = nil,
        agentConfig: SessionRegistry.AgentConfig,
        profileRouting: ProfileRoutingConfig = ProfileRoutingConfig()
    ) {
        let pm = ProfileManager()
        let dm = DeliveryManager()
        SendMessageTool.delivery = dm
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
            onUI: nil
        )

        // Build platform adapters from gateway config (or legacy token flag).
        // The AsyncHTTPClient is created ONLY when an adapter consumes it and
        // is retained: a discarded client deinits with a fatal ("Client not
        // shut down before the deinit"), and with no adapters configured the
        // old unretained local trapped the gateway at init.
        var httpClient: HTTPClient?
        var adapters: [any PlatformAdapter] = []
        if let config = gatewayConfig {
            if config.telegram.enabled, !config.telegram.botToken.isEmpty {
                let client = HTTPClient(eventLoopGroupProvider: .singleton)
                httpClient = client
                let adapter = TelegramAdapter(
                    botToken: config.telegram.botToken,
                    allowedUsers: config.telegram.allowedUsers,
                    allowAllUsers: config.telegram.allowAllUsers,
                    homeChannel: config.telegram.homeChannel,
                    typingIndicator: config.telegram.typingIndicator,
                    replyToMode: config.telegram.replyToMode,
                    requireMention: config.telegram.requireMention,
                    pollInterval: .seconds(config.telegram.pollIntervalSeconds),
                    httpClient: client
                )
                adapters.append(adapter)
            }
            if config.email.enabled, !config.email.address.isEmpty, !config.email.password.isEmpty {
                let adapter = EmailAdapter(config: config.email)
                adapters.append(adapter)
            }
            if config.slack.enabled, !config.slack.botToken.isEmpty, !config.slack.appToken.isEmpty {
                let client = HTTPClient(eventLoopGroupProvider: .singleton)
                httpClient = client
                let adapter = SlackAdapter(
                    botToken: config.slack.botToken,
                    appToken: config.slack.appToken,
                    allowedUsers: config.slack.allowedUsers,
                    allowAllUsers: config.slack.allowAllUsers,
                    homeChannel: config.slack.homeChannel,
                    replyToMode: config.slack.replyToMode,
                    requireMention: config.slack.requireMention,
                    httpClient: client,
                    eventLoopGroup: MultiThreadedEventLoopGroup.singleton
                )
                adapters.append(adapter)
            }
        } else if let token = telegramToken {
            let client = HTTPClient(eventLoopGroupProvider: .singleton)
            httpClient = client
            let adapter = TelegramAdapter(botToken: token, httpClient: client)
            adapters.append(adapter)
        }
        self.httpClient = httpClient
        self.platformAdapters = adapters
        self.sessionRouter = SessionRouter()

        // Cron execution harness: each due job becomes a one-shot agent
        // session under the default profile; the first response lands in
        // the job's `lastOutput` (capped by the scheduler).
        let cron = CronScheduler(
            store: RuntimeCronStore(),
            pollIntervalSeconds: 30,
            jobRunner: { job in
                let sessionID = "cron-\(job.id)"
                let handle = await reg.getOrCreate(sessionID: sessionID, profile: "default")
                let incoming = IncomingMessage(
                    id: UUID().uuidString,
                    chat: ChatTarget(platform: "cron", chatID: job.id),
                    text: job.prompt,
                    senderID: "cron"
                )
                handle.inputContinuation.yield(incoming)
                var output = ""
                for await response in handle.responses {
                    output = response
                    break // First response is the job result.
                }
                await reg.remove(sessionID: sessionID)
                return output.isEmpty ? "Job processed (no response)." : output
            }
        )
        self.cronScheduler = cron
    }

    // MARK: - Service

    public func run() async throws {
        logger.info("Starting ARC Agent Gateway (Bot Mode)...")

        var services: [any Service] = [httpServer, wsServer, botMessaging, cronScheduler]

        // Register adapters for delivery, then ingest their messages into
        // sessions — routing each chat to the profile its route table
        // specifies (default when unmatched). The consumption tasks' lifetime
        // is bounded by each adapter's AsyncStream.
        for adapter in platformAdapters {
            await deliveryManager.register(adapter: adapter)
            services.append(adapter)
            Task {
                for await incoming in adapter.incomingMessages {
                    let profile = ProfileRouteResolver.profile(
                        for: incoming.chat,
                        routes: self.profileRoutes,
                        multiplexProfiles: self.multiplexProfiles
                    ) ?? "default"
                    let sessionID = await self.sessionRouter.resolve(chat: incoming.chat)
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
            // teardown, and the adapter HTTP client — an unshutdown
            // AsyncHTTPClient traps on deinit.
            if let httpClient { try? await httpClient.shutdown() }
            await TesseraConnection.shared.shutdown()
            throw error
        }
        // Release the shared Tessera connection (WireGuard tunnel) at
        // teardown.
        if let httpClient { try? await httpClient.shutdown() }
        await TesseraConnection.shared.shutdown()
    }
}
