import Foundation
import Hummingbird
import HummingbirdRouter
import NIOCore
import ServiceLifecycle
import Logging

/// An HTTP server exposing the gateway's REST API.
///
/// Serves as the REST API layer of the gateway; the web UI is a separate
/// process (`arc-agent-webui`, on no-webui's `WebUIServer`). The server is a
/// ``Service`` managed by the gateway's ``ServiceGroup``.
///
/// **Endpoints:**
/// - `POST /v1/chat` — Send a message to an agent session
/// - `GET /health` — Health check
public final class HTTPServerService: Service {

    public struct Configuration: Sendable {
        public let host: String
        public let port: Int

        public init(host: String = "127.0.0.1", port: Int = 8080) {
            self.host = host
            self.port = port
        }
    }

    private let config: Configuration
    private let onChat: @Sendable (String, String) async throws -> String

    /// Create an HTTP server service.
    /// - Parameters:
    ///   - config: Server configuration (host, port).
    ///   - onChat: Closure called when a chat request arrives.
    public init(
        config: Configuration = .init(),
        onChat: @escaping @Sendable (String, String) async throws -> String
    ) {
        self.config = config
        self.onChat = onChat
    }

    public func run() async throws {
        let router = RouterBuilder(context: BasicRouterRequestContext.self) {
            Get("/health") { _, _ in
                HTTPResponse.Status.ok
            }
            RouteGroup("/v1") {
                Post("/chat") { [onChat] request, context in
                    let body = try await request.decode(as: ChatRequest.self, context: context)
                    let response = try await onChat(body.sessionID, body.message)
                    return ChatResponse(response: response)
                }
            }
        }

        let app = Application(
            responder: router,
            server: .http1(),
            configuration: .init(
                address: .hostname(config.host, port: config.port)
            )
        )
        // `ServiceGroup.run()` is signal-driven and NOT task-cancellation
        // aware: a `Task { try await server.run() }; task.cancel()` (as test
        // teardown does) would leave the server and its NIO event-loop
        // threads alive, so the test process could never exit. Wire task
        // cancellation to the group's graceful shutdown — cancel now stops
        // the server cleanly instead of leaking a MultiThreadedEventLoopGroup.
        // Signal handling is unchanged from `runService()`.
        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [app],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: Logger(label: "arc-http-server")
            )
        )
        try await withTaskCancellationHandler {
            try await serviceGroup.run()
        } onCancel: {
            // onCancel is synchronous; the group coalesces racing triggers
            // and `run()` returns once every service has shut down.
            Task { await serviceGroup.triggerGracefulShutdown() }
        }
    }
}

// MARK: - Request/Response Models

struct ChatRequest: Decodable, Sendable {
    let sessionID: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case message
    }
}

struct ChatResponse: Encodable, Sendable, ResponseEncodable {
    let response: String
}
