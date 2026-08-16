import Foundation
import AsyncHTTPClient
import ServiceLifecycle
import Logging

/// The top-level gateway service that manages the HTTP server, platform
/// adapters, agent cache, and message routing.
///
/// ``GatewayService`` is a ``Service`` that composes all gateway components
/// into a single lifecycle-managed tree:
///
/// ```
/// GatewayService
/// ├── HTTPServerService (Hummingbird)
/// ├── PlatformAdapters (Telegram, etc.)
/// ├── AgentCache
/// └── Dispatcher (internal)
/// ```
///
/// The gateway runs as a daemon, accepting messages from multiple platforms
/// and routing them to agent sessions.
public final class GatewayService: Service {

    public struct Configuration: Sendable {
        public var http: HTTPServerService.Configuration
        public var telegramBotToken: String?
        public var maxCachedAgents: Int
        public var agentIdleTTL: Duration

        public init(
            http: HTTPServerService.Configuration = .init(),
            telegramBotToken: String? = nil,
            maxCachedAgents: Int = 100,
            agentIdleTTL: Duration = .seconds(1800)
        ) {
            self.http = http
            self.telegramBotToken = telegramBotToken
            self.maxCachedAgents = maxCachedAgents
            self.agentIdleTTL = agentIdleTTL
        }
    }

    private let config: Configuration
    private let agentFactory: @Sendable (String) async -> ArcAgent
    private let logger: Logger

    private let httpClient: HTTPClient
    private let agentCache: AgentCache
    private let sessionRouter: SessionRouter
    private let deliveryManager: DeliveryManager

    /// Create a gateway service.
    /// - Parameters:
    ///   - config: Gateway configuration.
    ///   - agentFactory: Closure that creates an ``ArcAgent`` for a given
    ///     session ID. Called on cache miss.
    ///   - logger: Logger for gateway events.
    public init(
        config: Configuration,
        agentFactory: @escaping @Sendable (String) async -> ArcAgent,
        logger: Logger
    ) {
        self.config = config
        self.agentFactory = agentFactory
        self.logger = logger
        self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        self.agentCache = AgentCache(
            maxSize: config.maxCachedAgents,
            idleTTL: config.agentIdleTTL
        )
        self.sessionRouter = SessionRouter()
        self.deliveryManager = DeliveryManager()
    }

    public func run() async throws {
        logger.info("Gateway starting")

        // Build the HTTP server with a closure that routes through the cache
        let httpServer = HTTPServerService(config: config.http) { [agentCache, agentFactory] sessionID, message in
            let agent = await agentCache.getOrCreate(sessionID: sessionID) {
                await agentFactory(sessionID)
            }
            return try await agent.runConversation(message: message)
        }

        // Collect platform adapters
        var services: [any Service] = [httpServer]

        if let token = config.telegramBotToken {
            let telegram = TelegramAdapter(
                botToken: token,
                httpClient: httpClient
            )
            await deliveryManager.register(adapter: telegram)
            services.append(telegram)
            logger.info("Telegram adapter registered")
        }

        // Run all services in a service group
        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: services,
                logger: logger
            )
        )

        // Start a background task for idle agent sweeping
        let sweepTask = Task { [weak agentCache] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await agentCache?.sweepIdle()
            }
        }

        do {
            try await serviceGroup.run()
        } catch {
            logger.error("Gateway stopped with error: \(error)")
        }

        sweepTask.cancel()
        try? await httpClient.shutdown()
        logger.info("Gateway stopped")
    }
}
