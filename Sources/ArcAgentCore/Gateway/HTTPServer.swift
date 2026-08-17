import Foundation
import Hummingbird
import HummingbirdRouter
import NIOCore
import ServiceLifecycle

/// An HTTP server that exposes the agent's API endpoints and web UI.
///
/// Serves as the REST API and web interface layer of the gateway.
/// The server is a ``Service`` managed by the gateway's ``ServiceGroup``.
///
/// **Endpoints:**
/// - `GET /ui` — Web UI (chat interface)
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
    private let onUI: (@Sendable () async -> String)?

    /// Create an HTTP server service.
    /// - Parameters:
    ///   - config: Server configuration (host, port).
    ///   - onChat: Closure called when a chat request arrives.
    ///   - onUI: Optional async closure that returns the web UI HTML.
    public init(
        config: Configuration = .init(),
        onChat: @escaping @Sendable (String, String) async throws -> String,
        onUI: (@Sendable () async -> String)? = nil
    ) {
        self.config = config
        self.onChat = onChat
        self.onUI = onUI
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
            // Web UI route — serves the complete chat interface
            Get("/ui") { [onUI] _, _ in
                let html = await onUI?() ?? "<h1>Web UI not configured</h1>"
                let buffer = ByteBuffer(string: html)
                return Response(
                    status: .ok,
                    headers: [.contentType: "text/html; charset=utf-8"],
                    body: .init(byteBuffer: buffer)
                )
            }
        }

        let app = Application(
            responder: router,
            server: .http1(),
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
