import Foundation
import NIOCore
import NIOWebSocket

public actor WebSocketHandler {
    public let sessionID: String
    private var channel: Channel?
    private var currentModel: String = "default"
    private let registry: SessionRegistry

    public init(sessionID: String, registry: SessionRegistry) {
        self.sessionID = sessionID
        self.registry = registry
    }

    func setChannel(_ channel: Channel) {
        self.channel = channel
    }

    func handleInbound(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let command = try? JSONDecoder().decode(WSIncoming.self, from: data)
        else { return }

        switch command.type {
        case "message":
            guard let msgText = command.text, !msgText.isEmpty else { return }

            try? await send(text: "{\"type\":\"status\",\"text\":\"streaming\"}")

            let handle = await registry.getOrCreate(sessionID: sessionID, profile: currentModel)

            let incoming = IncomingMessage(
                id: UUID().uuidString,
                chat: ChatTarget(platform: "webui", chatID: sessionID),
                text: msgText,
                senderID: "webui"
            )

            handle.inputContinuation.yield(incoming)

            // Consume exactly ONE response for this message. The shared
            // `responses` stream only terminates when the *whole* agent ends
            // (its input stream closes or it errors) — never after a single
            // response — so draining it with a bare `for await` would hang
            // forever and the `done` frame would never be sent. That left the
            // web UI stuck "streaming" with the input disabled after every
            // turn. Mirrors the HTTP path (GatewayService.onChat), which takes
            // the first response and breaks. If the agent finished without
            // yielding anything (it threw), surface an error instead of
            // silently hanging.
            if let response = await Self.nextResponse(handle.responses) {
                try? await send(text: "{\"type\":\"token\",\"text\":\"\(escapeJSON(response))\"}")
            } else {
                try? await send(text: "{\"type\":\"error\",\"text\":\"No response from agent\"}")
            }

            try? await send(text: "{\"type\":\"done\"}")

        case "regenerate":
            try? await send(text: "{\"type\":\"status\",\"text\":\"streaming\"}")
            try? await send(text: "{\"type\":\"token\",\"text\":\"Regenerating...\"}")
            try? await send(text: "{\"type\":\"done\"}")

        case "set_model":
            if let model = command.text {
                currentModel = model
            }

        case "ping":
            try? await send(text: "{\"type\":\"pong\"}")

        default:
            break
        }
    }

    func send(text: String) async throws {
        guard let channel = self.channel else { return }
        let buffer = channel.allocator.buffer(string: text)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        try await channel.writeAndFlush(frame, promise: nil)
    }

    /// Take exactly the **next** element from `stream`, or `nil` if the
    /// stream finished without yielding anything.
    ///
    /// This is the testable seam for the one-response-per-message contract.
    /// `SessionHandle.responses` is a stream that only terminates when the
    /// whole agent ends (its input stream closes or it throws) — it is NOT
    /// terminated after each single response. A chat handler that *drains*
    /// the stream (a bare `for await ...` with no `break`) would therefore
    /// block forever and never emit the trailing `done` frame, leaving the
    /// web UI stuck "streaming" with the input disabled. Taking the first
    /// element and stopping is correct and is what the HTTP path does.
    nonisolated static func nextResponse(_ stream: AsyncStream<String>) async -> String? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    private func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

struct WSIncoming: Decodable, Sendable {
    let type: String
    let text: String?
}
