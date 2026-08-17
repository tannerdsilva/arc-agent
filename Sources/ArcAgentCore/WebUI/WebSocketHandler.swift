import Foundation
import NIOCore
import NIOWebSocket

// MARK: - WebSocket Handler Actor

/// Manages a single WebSocket connection for a browser session.
///
/// Each browser tab opens one WebSocket connection.
/// The handler is an actor — all state mutations are serialized.
///
/// ## Message Protocol
///
/// **Incoming** (browser → server):
/// ```json
/// {"type": "message", "text": "Hello"}
/// {"type": "ping"}
/// ```
///
/// **Outgoing** (server → browser):
/// ```json
/// {"type": "token", "text": "Hello"}
/// {"type": "message", "html": "<p>Hello</p>"}
/// {"type": "status", "text": "Thinking..."}
/// {"type": "pong"}
/// ```
public actor WebSocketHandler {
    /// The unique session ID for this connection.
    public let sessionID: String
    /// The NIO WebSocket channel for sending messages.
    private var channel: Channel?

    /// Create a WebSocket handler.
    /// - Parameter sessionID: The session identifier.
    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Set the channel for this handler (called after upgrade).
    func setChannel(_ channel: Channel) {
        self.channel = channel
    }

    /// Handle an incoming WebSocket message.
    /// - Parameter text: The raw message text from the browser.
    func handleInbound(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let command = try? JSONDecoder().decode(WSIncoming.self, from: data)
        else { return }

        switch command.type {
        case "message":
            // Phase W3: Echo the message back for now.
            // Phase W4+: Forward to SessionAgent and stream the response.
            let echo = """
            {"type":"message","html":"<p>\(htmlEscape(command.text ?? ""))</p>"}
            """
            try? await send(text: echo)

        case "ping":
            try? await send(text: "{\"type\":\"pong\"}")

        default:
            break
        }
    }

    /// Send a text message over the WebSocket.
    /// - Parameter text: The message to send.
    func send(text: String) async throws {
        guard let channel = self.channel else { return }
        let buffer = channel.allocator.buffer(string: text)
        let frame = WebSocketFrame(
            fin: true,
            opcode: .text,
            data: buffer
        )
        try await channel.writeAndFlush(frame, promise: nil)
    }

    /// Stream a response token to the browser.
    /// - Parameter text: The token text.
    func streamToken(_ text: String) async throws {
        let payload = "{\"type\":\"token\",\"text\":\"\(text)\"}"
        try await send(text: payload)
    }

    /// Send a complete message to the browser.
    /// - Parameters:
    ///   - html: The pre-rendered HTML content.
    ///   - role: The message role ("user" or "assistant").
    func sendMessage(html: String, role: String) async throws {
        let payload = "{\"type\":\"message\",\"html\":\"\(html)\",\"role\":\"\(role)\"}"
        try await send(text: payload)
    }

    /// Update the connection status in the browser.
    /// - Parameter connected: Whether the connection is active.
    func updateStatus(connected: Bool) async throws {
        let status = connected ? "Connected" : "Disconnected"
        let payload = "{\"type\":\"status\",\"text\":\"\(status)\"}"
        try await send(text: payload)
    }
}

// MARK: - Message Types

/// Incoming WebSocket message from the browser.
struct WSIncoming: Decodable, Sendable {
    let type: String
    let text: String?
}
