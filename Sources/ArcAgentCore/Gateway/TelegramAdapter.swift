import Foundation
import AsyncHTTPClient
import NIO
import Logging

/// A platform adapter for Telegram using the Bot API with long polling.
///
/// Feature surface (reference telegram parity, text transport):
/// - long-poll `getUpdates` with persisted offset
/// - `sendMessage` with MarkdownV2 escaping, reply threading, forum topics
/// - streaming in-place edits via `editMessageText`
/// - `sendChatAction` typing indicator
/// - per-user / per-chat allowlist authz + mention gating
/// - code-aware chunking at Telegram's 4096-char limit
///
/// The adapter is a ``Service`` — its `run()` method polls until cancelled.
public final class TelegramAdapter: PlatformAdapter {

    public let name = "telegram"
    public let incomingMessages: AsyncStream<IncomingMessage>

    /// Maximum message length for sendMessage/editMessageText (MarkdownV2).
    public static let maxMessageLength = 4096

    private let botToken: String
    private let baseURL: String
    private let httpClient: HTTPClient
    private let pollInterval: Duration
    private let authz: AuthzPolicy
    private let typingIndicatorEnabled: Bool
    private let replyToMode: String
    private let continuation: AsyncStream<IncomingMessage>.Continuation
    /// Bot's own numeric id (learned from getMe); used for mention checks.
    private nonisolated(unsafe) var botID: Int? = nil
    private nonisolated(unsafe) var botUsername: String? = nil
    private nonisolated(unsafe) var lastUpdateID: Int = 0
    /// Chat type strings Telegram reports: "private", "group", "supergroup", "channel".
    private let logger = Logging.Logger(label: "com.arc-agent.telegram-adapter")

    /// - Parameters:
    ///   - botToken: Telegram Bot API token.
    ///   - allowedUsers: User ids allowed to talk to the bot (empty = only if allowAllUsers).
    ///   - allowAllUsers: Permit any user.
    ///   - homeChannel: Default chat id for cron/notification delivery.
    ///   - typingIndicator: Send `typing` chat actions while turns run.
    ///   - replyToMode: `off` | `first` | `all` (thread replies to triggering message).
    ///   - requireMention: In groups/channels the bot must be mentioned.
    ///   - pollInterval: How often to poll for updates.
    ///   - httpClient: Shared HTTP client.
    ///   - baseURLOverride: Test seam (defaults to api.telegram.org).
    public init(
        botToken: String,
        allowedUsers: Set<String> = [],
        allowAllUsers: Bool = false,
        homeChannel: String? = nil,
        typingIndicator: Bool = true,
        replyToMode: String = "first",
        requireMention: Bool = false,
        pollInterval: Duration = .seconds(1),
        httpClient: HTTPClient,
        baseURLOverride: String? = nil
    ) {
        self.botToken = botToken
        self.baseURL = baseURLOverride ?? "https://api.telegram.org/bot\(botToken)"
        self.httpClient = httpClient
        self.pollInterval = pollInterval
        self.authz = AuthzPolicy(
            allowedUsers: allowedUsers,
            allowAllUsers: allowAllUsers,
            requireMention: requireMention
        )
        self.typingIndicatorEnabled = typingIndicator
        self.replyToMode = replyToMode
        self.homeChannel = homeChannel

        var cont: AsyncStream<IncomingMessage>.Continuation!
        self.incomingMessages = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// Default chat for cron/notification delivery on this platform.
    public let homeChannel: String?

    public var canEditMessages: Bool { true }

    // MARK: - Service

    public func run() async throws {
        try await withTaskCancellationHandler {
            // Learn identity once (mention gating needs the bot's username).
            if botID == nil {
                await identify()
            }
            while !Task.isCancelled {
                do {
                    try await poll()
                } catch {
                    logger.warning("telegram poll failed: \(error)")
                }
                try await Task.sleep(for: self.pollInterval)
            }
        } onCancel: {
            self.continuation.finish()
        }
    }

    // MARK: - Sending

    public func send(message: OutgoingMessage, to target: ChatTarget) async throws -> SendResult {
        let chunks = PlatformChunker.chunk(
            TelegramFormat.format(message.text),
            maxLength: Self.maxMessageLength
        )
        var firstID: String? = nil
        for (idx, chunk) in chunks.enumerated() {
            let replyID: String? = replyToID(for: idx, count: chunks.count, replyTo: target.threadID)
            let result = try await baseSend(text: chunk, to: target, replyTo: replyID)
            if firstID == nil { firstID = result }
        }
        // Deliverable mode: native attachments (document upload).
        if let attachments = message.attachments, !attachments.isEmpty {
            var failures: [String] = []
            for attachment in attachments {
                guard let path = attachment.localPath else {
                    failures.append("\(attachment.filename): no local path")
                    continue
                }
                do {
                    try await sendDocument(path: path, caption: attachment.filename, to: target)
                } catch {
                    failures.append("\(attachment.filename): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                _ = try? await baseSend(
                    text: "⚠️ Upload failed: " + failures.joined(separator: "; "),
                    to: target, replyTo: nil
                )
            }
        }
        return SendResult(messageID: firstID)
    }

    // MARK: - Deliverables (reference `features/deliverable-mode.md`)

    /// Upload one local file as a Telegram document (multipart/form-data).
    func sendDocument(path: String, caption: String, to target: ChatTarget) async throws {
        let data = try Self.buildMultipart(
            fields: ["chat_id": target.chatID, "caption": caption],
            fileField: "document",
            filePath: path
        )
        var request = HTTPClientRequest(url: "\(baseURL)/sendDocument")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(Self.multipartBoundary)")
        request.headers.add(name: "Content-Length", value: "\(data.count)")
        request.body = .bytes(data)
        let response = try await httpClient.execute(request, timeout: .seconds(120))
        let body = Data(buffer: try await response.body.collect(upTo: 4 * 1024 * 1024))
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TelegramError.badPayload
        }
        if let ok = json["ok"] as? Bool, !ok {
            let desc = json["description"] as? String ?? "unknown"
            throw TelegramError.rejected(desc)
        }
    }

    static let multipartBoundary = "arc-agent-deliverable-boundary"

    /// Multipart/form-data body with one file field (only for the Telegram
    /// Bot API `sendDocument` shape; unit-tested without network).
    static func buildMultipart(fields: [String: String], fileField: String, filePath: String) throws -> Data {
        let fileData = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
        let filename = URL(fileURLWithPath: filePath).lastPathComponent
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (key, value) in fields {
            append("--\(multipartBoundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(multipartBoundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(multipartBoundary)--\r\n")
        return body
    }

    public func sendTyping(to target: ChatTarget) async throws {
        guard typingIndicatorEnabled else { return }
        _ = try? await post(method: "sendChatAction", params: [
            "chat_id": target.chatID,
            "action": "typing",
        ])
    }

    public func sendUpdate(messageID: String, text: String, parseMode: String?, to target: ChatTarget) async throws {
        let formatted = TelegramFormat.format(text)
        guard formatted.count <= Self.maxMessageLength else {
            // Too long to edit in place; the gateway falls back to re-sending.
            throw GatewayError.unsupportedOperation("telegram: edit exceeds 4096")
        }
        var params: [String: Any] = [
            "chat_id": target.chatID,
            "message_id": messageID,
            "text": formatted,
            "parse_mode": "MarkdownV2",
        ]
        if let thread = target.threadID {
            params["message_thread_id"] = thread
        }
        _ = try await post(method: "editMessageText", params: params)
    }

    // MARK: - Private

    private func baseSend(text: String, to target: ChatTarget, replyTo: String?) async throws -> String? {
        var params: [String: Any] = [
            "chat_id": target.chatID,
            "text": text,
            "parse_mode": "MarkdownV2",
        ]
        if let thread = target.threadID {
            params["message_thread_id"] = thread
        }
        if let replyTo {
            params["reply_to_message_id"] = replyTo
        }
        let json = try await post(method: "sendMessage", params: params)
        return (json?["message_id"] as? Int).map(String.init)
    }

    /// Post to a Bot API method; returns the `result` object on success.
    private func post(method: String, params: [String: Any]) async throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: params)
        var request = HTTPClientRequest(url: "\(baseURL)/\(method)")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(data: data))

        let response = try await httpClient.execute(request, timeout: .seconds(30))
        let body = try await response.body.collect(upTo: 4 * 1024 * 1024)
        guard 200..<300 ~= response.status.code else {
            logger.warning("telegram \(method) failed: HTTP \(response.status.code)")
            throw TelegramError.apiError(status: response.status.code)
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any] else {
            throw TelegramError.badPayload
        }
        if let ok = json["ok"] as? Bool, !ok {
            let desc = json["description"] as? String ?? "unknown"
            logger.warning("telegram \(method) rejected: \(desc)")
            throw TelegramError.rejected(desc)
        }
        return json["result"] as? [String: Any] ?? (json["result"].map { ["value": $0] })
    }

    private func replyToID(for index: Int, count: Int, replyTo: String?) -> String? {
        guard let replyTo else { return nil }
        switch replyToMode {
        case "all": return replyTo
        case "first": return index == 0 ? replyTo : nil
        default: return nil
        }
    }

    private func identify() async {
        guard let json = try? await post(method: "getMe", params: [:]) else { return }
        botID = json["id"] as? Int
        botUsername = json["username"] as? String
    }

    private func poll() async throws {
        var url = "\(baseURL)/getUpdates?timeout=10"
        if lastUpdateID > 0 {
            url += "&offset=\(lastUpdateID + 1)"
        }

        let request = HTTPClientRequest(url: url)
        let response = try await httpClient.execute(request, timeout: .seconds(15))
        let body = try await response.body.collect(upTo: 8 * 1024 * 1024)
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

            guard let message = update["message"] as? [String: Any] ?? update["edited_message"] as? [String: Any] else { continue }
            guard let chat = message["chat"] as? [String: Any], let chatID = chat["id"] as? Int else { continue }
            let chatType = chat["type"] as? String
            // Skip the bot's own messages (echo suppression).
            if let from = message["from"] as? [String: Any], let fromID = from["id"] as? Int, fromID == botID {
                continue
            }
            guard let text = message["text"] as? String else { continue }

            let messageID = "\(message["message_id"] as? Int ?? 0)"
            let from = message["from"] as? [String: Any]
            let senderID = "\(from?["id"] as? Int ?? 0)"
            let senderName = from?["first_name"] as? String

            let target = ChatTarget(
                platform: "telegram",
                chatID: "\(chatID)",
                threadID: (message["message_thread_id"] as? Int).map(String.init)
            )
            let isMention = text.contains("@\(botUsername ?? "")")
            guard authz.allows(senderID: senderID, chat: target, isMention: isMention, chatType: chatType) else {
                logger.debug("telegram: denied sender \(senderID) in \(chatID)")
                continue
            }

            let rawUpdate: AnySendable? = (try? JSONSerialization.data(withJSONObject: update))
                .map { AnySendable(Data($0) as Data) }

            continuation.yield(IncomingMessage(
                id: messageID,
                chat: target,
                text: text,
                senderID: senderID,
                senderName: senderName,
                isReply: message["reply_to_message"] != nil,
                isMention: isMention,
                raw: rawUpdate.map { ["update": $0] }
            ))
        }
    }
}

enum TelegramError: Error {
    case apiError(status: UInt)
    case badPayload
    case rejected(String)
}
