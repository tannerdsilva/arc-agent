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

            for await response in handle.responses {
                let escaped = escapeJSON(response)
                try? await send(text: "{\"type\":\"token\",\"text\":\"\(escaped)\"}")
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
