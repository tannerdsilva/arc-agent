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
/// {"type": "regenerate"}
/// {"type": "set_model", "model": "gpt-4o"}
/// {"type": "ping"}
/// ```
///
/// **Outgoing** (server → browser):
/// ```json
/// {"type": "token", "text": "Hello"}
/// {"type": "message", "html": "<p>Hello</p>", "role": "assistant"}
/// {"type": "done"}
/// {"type": "error", "text": "Something went wrong"}
/// {"type": "status", "text": "streaming"}
/// {"type": "pong"}
/// ```
public actor WebSocketHandler {
    /// The unique session ID for this connection.
    public let sessionID: String
    /// The NIO WebSocket channel for sending messages.
    private var channel: Channel?
    /// The current model name.
    private var currentModel: String = "default"
    /// Reference to the session registry for routing messages.
    private let registry: SessionRegistry

    /// Create a WebSocket handler.
    /// - Parameters:
    ///   - sessionID: The session identifier.
    ///   - registry: The session registry for routing messages.
    public init(sessionID: String, registry: SessionRegistry) {
        self.sessionID = sessionID
        self.registry = registry
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
            guard let msgText = command.text, !msgText.isEmpty else { return }

            // Route through the session registry
            let handle = await registry.getOrCreate(sessionID: sessionID, profile: currentModel)

            let incoming = IncomingMessage(
                id: UUID().uuidString,
                chat: ChatTarget(platform: "webui", chatID: sessionID),
                text: msgText,
                senderID: "webui"
            )

            // Send streaming status
            try? await send(text: "{\"type\":\"status\",\"text\":\"streaming\"}")

            // Yield the message to the agent
            handle.inputContinuation.yield(incoming)

            // Stream responses back to the browser
            for await response in handle.responses {
                let escaped = response
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\t", with: "\\t")
                try? await send(text: "{\"type\":\"token\",\"text\":\"\(escaped)\"}")
            }

            try? await send(text: "{\"type\":\"done\"}")

        case "regenerate":
            // Regenerate the last response
            try? await send(text: "{\"type\":\"status\",\"text\":\"streaming\"}")
            let handle = await registry.getOrCreate(sessionID: sessionID, profile: currentModel)
            // Re-send the last message — for now just send a placeholder
            try? await send(text: "{\"type\":\"token\",\"text\":\"Regenerating...\"}")
            try? await send(text: "{\"type\":\"done\"}")

        case "set_model":
            if let model = command.text {
                currentModel = model
                try? await send(text: "{\"type\":\"status\",\"text\":\"Model set to \(model)\"}")
            }

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
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        let payload = "{\"type\":\"token\",\"text\":\"\(escaped)\"}"
        try await send(text: payload)
    }

    /// Send a complete message to the browser.
    /// - Parameters:
    ///   - html: The pre-rendered HTML content.
    ///   - role: The message role ("user" or "assistant").
    func sendMessage(html: String, role: String) async throws {
        let escaped = html
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let payload = "{\"type\":\"message\",\"html\":\"\(escaped)\",\"role\":\"\(role)\"}"
        try? await send(text: payload)
    }

    /// Signal that streaming is complete.
    func sendDone() async throws {
        try? await send(text: "{\"type\":\"done\"}")
    }

    /// Send an error message.
    func sendError(_ text: String) async throws {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try? await send(text: "{\"type\":\"error\",\"text\":\"\(escaped)\"}")
    }

    /// Update the connection status in the browser.
    /// - Parameter connected: Whether the connection is active.
    func updateStatus(connected: Bool) async throws {
        let status = connected ? "Connected" : "Disconnected"
        let payload = "{\"type\":\"status\",\"text\":\"\(status)\"}"
        try? await send(text: payload)
    }
}

// MARK: - Message Types

/// Incoming WebSocket message from the browser.
struct WSIncoming: Decodable, Sendable {
    let type: String
    let text: String?
}
