import Foundation
import AsyncHTTPClient
import ServiceLifecycle
import Logging

/// The top-level gateway service that manages the HTTP server, platform
/// adapters, session registry, and message routing.
///
/// ``GatewayService`` is a ``Service`` that composes:
/// - ``HTTPServerService`` — REST API endpoints
/// - ``TelegramAdapter`` — Telegram Bot API long polling
/// - ``SessionRegistry`` — active session agents (no cache, LMDB is source of truth)
/// - ``DeliveryManager`` — routes responses to the correct platform
///
/// All components are managed by a ``ServiceGroup``. The gateway creates
/// session agents on demand and lets the Service Lifecycle framework
/// handle idle timeouts and cleanup.
public struct GatewayService: Service {

    private let httpServer: HTTPServerService
    private let telegramAdapter: TelegramAdapter?
    private let registry: SessionRegistry
    private let deliveryManager: DeliveryManager
    private let logger: Logger

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        telegramToken: String? = nil,
        agentConfig: SessionRegistry.AgentConfig
    ) {
        self.deliveryManager = DeliveryManager()
        self.registry = SessionRegistry(
            agentConfig: agentConfig,
            deliveryManager: deliveryManager
        )
        self.logger = Logger(label: "com.arc-agent.gateway")

        // Build the HTTP server with a reference to the registry
        self.httpServer = HTTPServerService(
            config: .init(host: host, port: port),
            onChat: { [registry] sessionID, message in
                let continuation = await registry.getOrCreate(sessionID: sessionID)
                let incoming = IncomingMessage(
                    id: UUID().uuidString,
                    chat: ChatTarget(platform: "api", chatID: sessionID),
                    text: message,
                    senderID: "api"
                )
                continuation.yield(incoming)
                return "Message received"
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
        logger.info("Starting ARC Agent Gateway...")

        var services: [any Service] = [httpServer]
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
