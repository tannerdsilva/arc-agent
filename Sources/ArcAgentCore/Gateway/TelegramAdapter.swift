import Foundation
import AsyncHTTPClient
import NIO

/// A platform adapter for Telegram using the Bot API with long polling.
///
/// Polls `getUpdates` for new messages and produces them on an
/// ``AsyncStream``. Sends messages via `sendMessage`.
///
/// The adapter is a ``Service`` — its `run()` method polls until
/// cancelled, then shuts down the HTTP client.
public final class TelegramAdapter: PlatformAdapter {

    public let name = "telegram"
    public let incomingMessages: AsyncStream<IncomingMessage>

    private let botToken: String
    private let baseURL: String
    private let httpClient: HTTPClient
    private let pollInterval: Duration
    private let continuation: AsyncStream<IncomingMessage>.Continuation
    private nonisolated(unsafe) var lastUpdateID: Int = 0

    /// Create a Telegram adapter.
    /// - Parameters:
    ///   - botToken: Telegram Bot API token.
    ///   - pollInterval: How often to poll for updates (default: 1 second).
    ///   - httpClient: Shared HTTP client.
    public init(
        botToken: String,
        pollInterval: Duration = .seconds(1),
        httpClient: HTTPClient
    ) {
        self.botToken = botToken
        self.baseURL = "https://api.telegram.org/bot\(botToken)"
        self.httpClient = httpClient
        self.pollInterval = pollInterval

        var cont: AsyncStream<IncomingMessage>.Continuation!
        self.incomingMessages = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func run() async throws {
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                try await poll()
                try await Task.sleep(for: self.pollInterval)
            }
        } onCancel: {
            self.continuation.finish()
        }
    }

    public func send(message: OutgoingMessage, to target: ChatTarget) async throws {
        var body: [String: Any] = [
            "chat_id": target.chatID,
            "text": message.text,
        ]
        if let parseMode = message.parseMode {
            body["parse_mode"] = parseMode.uppercased()
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = HTTPClientRequest(url: "\(baseURL)/sendMessage")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(data: data))

        let response = try await httpClient.execute(request, timeout: .seconds(30))
        guard 200..<300 ~= response.status.code else {
            throw TelegramError.apiError(status: response.status.code)
        }
    }

    // MARK: - Private

    private func poll() async throws {
        var url = "\(baseURL)/getUpdates?timeout=10"
        if lastUpdateID > 0 {
            url += "&offset=\(lastUpdateID + 1)"
        }

        let request = HTTPClientRequest(url: url)
        let response = try await httpClient.execute(request, timeout: .seconds(15))
        let body = try await response.body.collect(upTo: 1024 * 1024)
        let data = Data(buffer: body)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ok = json["ok"] as? Bool, ok,
            let result = json["result"] as? [[String: Any]]
        else {
            return
        }

        for update in result {
            guard let updateID = update["update_id"] as? Int else { continue }
            lastUpdateID = max(lastUpdateID, updateID)

            guard
                let message = update["message"] as? [String: Any] ?? update["edited_message"] as? [String: Any],
                let chat = message["chat"] as? [String: Any],
                let chatID = chat["id"] as? Int,
                let text = message["text"] as? String
            else { continue }

            let messageID = "\(message["message_id"] as? Int ?? 0)"
            let from = message["from"] as? [String: Any]
            let senderID = "\(from?["id"] as? Int ?? 0)"
            let senderName = from?["first_name"] as? String

            // The raw update is an arbitrary JSON dictionary (not Sendable).
            // Store a JSON snapshot so the metadata stays Sendable.
            let rawUpdate: AnySendable? = (try? JSONSerialization.data(withJSONObject: update))
                .map(AnySendable.init)

            let incoming = IncomingMessage(
                id: messageID,
                chat: ChatTarget(platform: "telegram", chatID: "\(chatID)"),
                text: text,
                senderID: senderID,
                senderName: senderName,
                raw: rawUpdate.map { ["update": $0] }
            )
            continuation.yield(incoming)
        }
    }
}

enum TelegramError: Error {
    case apiError(status: UInt)
}
