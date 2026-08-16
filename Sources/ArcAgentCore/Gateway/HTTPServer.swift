import Foundation
import Hummingbird
import HummingbirdRouter
import ServiceLifecycle

/// An HTTP server that exposes the agent's API endpoints.
///
/// Serves as the REST API layer of the gateway, handling incoming chat
/// requests and health checks. The server is a ``Service`` managed by
/// the gateway's ``ServiceGroup``.
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
    ///   - onChat: Closure called when a chat request arrives. Receives the
    ///     session ID and message text, returns a response string.
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
            configuration: .init(
                address: .hostname(config.host, port: config.port)
            )
        )
        try await app.runService()
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
