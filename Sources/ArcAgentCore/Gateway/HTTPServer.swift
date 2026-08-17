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
/// - `GET /ui/bots` — Web UI (bot mode)
/// - `GET /ui/styles.css` — CSS stylesheet (dev mode only)
/// - `GET /ui/scripts.js` — JavaScript runtime (dev mode only)
/// - `POST /v1/chat` — Send a message to an agent session
/// - `GET /health` — Health check
public final class HTTPServerService: Service {

    public struct Configuration: Sendable {
        public let host: String
        public let port: Int
#if DEBUG
        /// In debug builds, CSS/JS are served from disk for live iteration.
        /// Set by the GatewayService based on build configuration.
        public let devMode: Bool

        public init(host: String = "127.0.0.1", port: Int = 8080, devMode: Bool = true) {
            self.host = host
            self.port = port
            self.devMode = devMode
        }
#else
        public init(host: String = "127.0.0.1", port: Int = 8080) {
            self.host = host
            self.port = port
        }
#endif
    }

    private let config: Configuration
    private let onChat: @Sendable (String, String) async throws -> String
    private let onUI: (@Sendable (String) async -> String)?

    /// Create an HTTP server service.
    /// - Parameters:
    ///   - config: Server configuration (host, port).
    ///   - onChat: Closure called when a chat request arrives.
    ///   - onUI: Optional async closure that returns the web UI HTML. Takes a mode string ("chat" or "bots").
    public init(
        config: Configuration = .init(),
        onChat: @escaping @Sendable (String, String) async throws -> String,
        onUI: (@Sendable (String) async -> String)? = nil
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
            // Web UI routes — serves the chat interface
            Get("/ui") { [onUI] _, _ in
                let html = await onUI?("chat") ?? "<h1>Web UI not configured</h1>"
                let buffer = ByteBuffer(string: html)
                return Response(
                    status: .ok,
                    headers: [.contentType: "text/html; charset=utf-8"],
                    body: .init(byteBuffer: buffer)
                )
            }
            Get("/ui/bots") { [onUI] _, _ in
                let html = await onUI?("bots") ?? "<h1>Web UI not configured</h1>"
                let buffer = ByteBuffer(string: html)
                return Response(
                    status: .ok,
                    headers: [.contentType: "text/html; charset=utf-8"],
                    body: .init(byteBuffer: buffer)
                )
            }
            Get("/ui/settings") { [onUI] _, _ in
                let html = await onUI?("settings") ?? "<h1>Web UI not configured</h1>"
                let buffer = ByteBuffer(string: html)
                return Response(
                    status: .ok,
                    headers: [.contentType: "text/html; charset=utf-8"],
                    body: .init(byteBuffer: buffer)
                )
            }
#if DEBUG
            // Dev mode: serve CSS/JS from disk for live iteration.
            // These routes are only compiled in debug builds.
            // Edit Assets/styles.css or Assets/scripts.js and refresh.
            Get("/ui/styles.css") { _, _ in
                let cssPath = "Sources/ArcAgentCore/WebUI/Assets/styles.css"
                let cwd = FileManager.default.currentDirectoryPath
                let fullPath = (cwd as NSString).appendingPathComponent(cssPath)
                guard let cssData = FileManager.default.contents(atPath: fullPath),
                      let css = String(data: cssData, encoding: .utf8)
                else {
                    return Response(status: .notFound)
                }
                return Response(
                    status: .ok,
                    headers: [.contentType: "text/css; charset=utf-8"],
                    body: .init(byteBuffer: ByteBuffer(string: css))
                )
            }
            Get("/ui/scripts.js") { _, _ in
                let jsPath = "Sources/ArcAgentCore/WebUI/Assets/scripts.js"
                let cwd = FileManager.default.currentDirectoryPath
                let fullPath = (cwd as NSString).appendingPathComponent(jsPath)
                guard let jsData = FileManager.default.contents(atPath: fullPath),
                      let js = String(data: jsData, encoding: .utf8)
                else {
                    return Response(status: .notFound)
                }
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/javascript; charset=utf-8"],
                    body: .init(byteBuffer: ByteBuffer(string: js))
                )
            }
#endif
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
