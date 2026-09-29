import Foundation
import AsyncHTTPClient
import NIO
import NIOCore
import NIOHTTP1
import NIOWebSocket
import Logging

/// A platform adapter for Slack using Socket Mode (WebSocket) + Web API.
///
/// reference slack parity (text transport):
/// - Socket Mode: `apps.connections.open` → WSS link → event envelope
///   handling (`events_api`, `slash_commands`), envelope acks, auto-reconnect
/// - `chat.postMessage` / `chat.update` sends + in-place edits
/// - mrkdwn conversion, threads (`thread_ts`), mention gating in channels
/// - per-user authz via the shared ``AuthzPolicy``
///
/// Slack has no Web API typing indicator (reference uses the Assistant
/// `assistant.threads.setStatus` surface); typing is a no-op here.
public final class SlackAdapter: PlatformAdapter {

    public let name = "slack"
    public let incomingMessages: AsyncStream<IncomingMessage>

    public static let maxMessageLength = 4000

    private let botToken: String
    private let appToken: String
    private let apiBase: String
    private let httpClient: HTTPClient
    private let group: EventLoopGroup
    private let authz: AuthzPolicy
    private let replyToMode: String
    private let continuation: AsyncStream<IncomingMessage>.Continuation
    private let logger = Logger(label: "com.arc-agent.slack-adapter")
    private nonisolated(unsafe) var botUserID: String? = nil
    private let socketURLOverride: String?
    private nonisolated(unsafe) var wsHandler: SlackWSHandler? = nil

    /// - Parameters:
    ///   - botToken: `xoxb-…` bot token.
    ///   - appToken: `xapp-…` app-level token with `connections:write` scope.
    ///   - allowedUsers / allowAllUsers: authz gate.
    ///   - homeChannel: Default channel for cron/notification delivery.
    ///   - replyToMode: `off` | `first` | `all` (thread replies).
    ///   - requireMention: In public/private channels the bot must be mentioned
    ///     (app mention). DMs always answer.
    ///   - apiBaseOverride / socketURLOverride: test seams.
    public init(
        botToken: String,
        appToken: String,
        allowedUsers: Set<String> = [],
        allowAllUsers: Bool = false,
        homeChannel: String? = nil,
        replyToMode: String = "first",
        requireMention: Bool = true,
        httpClient: HTTPClient,
        eventLoopGroup: EventLoopGroup,
        apiBaseOverride: String? = nil,
        socketURLOverride: String? = nil
    ) {
        self.botToken = botToken
        self.appToken = appToken
        self.apiBase = apiBaseOverride ?? "https://slack.com/api"
        self.httpClient = httpClient
        self.group = eventLoopGroup
        self.authz = AuthzPolicy(
            allowedUsers: allowedUsers,
            allowAllUsers: allowAllUsers,
            requireMention: requireMention
        )
        self.replyToMode = replyToMode
        self.homeChannel = homeChannel
        self.socketURLOverride = socketURLOverride

        var cont: AsyncStream<IncomingMessage>.Continuation!
        self.incomingMessages = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public let homeChannel: String?

    public var canEditMessages: Bool { true }

    // MARK: - Service

    public func run() async throws {
        try await withTaskCancellationHandler {
            await identify()
            while !Task.isCancelled {
                do {
                    try await runSocket()
                } catch {
                    logger.warning("slack socket dropped: \(error)")
                }
                try? await Task.sleep(for: .seconds(3))
            }
        } onCancel: {
            self.wsHandler?.close()
            self.continuation.finish()
        }
    }

    // MARK: - Sending

    public func send(message: OutgoingMessage, to target: ChatTarget) async throws -> SendResult {
        let chunks = PlatformChunker.chunk(
            SlackFormat.format(message.text),
            maxLength: Self.maxMessageLength
        )
        var firstTs: String? = nil
        let replyTs = target.threadID
        for (idx, chunk) in chunks.enumerated() {
            var params: [String: Any] = ["channel": target.chatID, "text": chunk]
            if idx == 0, let thread = replyTs {
                params["thread_ts"] = thread
            }
            if let json = try await webAPI(method: "chat.postMessage", params: params) {
                if let ts = json["ts"] as? String, firstTs == nil {
                    firstTs = ts
                }
            }
        }
        return SendResult(messageID: firstTs)
    }

    public func sendUpdate(messageID: String, text: String, parseMode: String?, to target: ChatTarget) async throws {
        let formatted = SlackFormat.format(text)
        guard formatted.count <= Self.maxMessageLength else {
            throw GatewayError.unsupportedOperation("slack: edit exceeds 4000")
        }
        _ = try await webAPI(method: "chat.update", params: [
            "channel": target.chatID,
            "ts": messageID,
            "text": formatted,
        ])
    }

    public func deleteMessage(messageID: String, to target: ChatTarget) async throws {
        _ = try await webAPI(method: "chat.delete", params: [
            "channel": target.chatID,
            "ts": messageID,
        ])
    }

    // MARK: - Private: HTTP

    private func webAPI(method: String, params: [String: Any]) async throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: params)
        var request = HTTPClientRequest(url: "\(apiBase)/\(method)")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(botToken)")
        request.headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        request.body = .bytes(ByteBuffer(data: data))
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        let body = try await response.body.collect(upTo: 8 * 1024 * 1024)
        guard 200..<300 ~= response.status.code else {
            throw SlackError.apiError("HTTP \(response.status.code)")
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any] else {
            throw SlackError.apiError("non-JSON response")
        }
        if (json["ok"] as? Bool) != true {
            logger.warning("slack \(method) error: \(String(describing: json["error"]))")
            throw SlackError.apiError(String(describing: json["error"] ?? "unknown"))
        }
        return json
    }

    private func identify() async {
        guard let json = try? await webAPI(method: "auth.test", params: [:]) else { return }
        botUserID = json["user_id"] as? String
    }

    // MARK: - Private: Socket Mode

    private func openSocketURL() async throws -> String {
        if let override = socketURLOverride { return override }
        guard let json = try await webAPI(method: "apps.connections.open", params: [:]) else {
            throw SlackError.connection
        }
        guard let url = json["url"] as? String else { throw SlackError.connection }
        return url
    }

    private func runSocket() async throws {
        let urlString = try await openSocketURL()
        guard let url = URL(string: urlString) else { throw SlackError.connection }
        let host = url.host ?? "wss-primary.slack.com"
        let port = url.port ?? 443
        let path = url.path + (url.query.map { "?" + $0 } ?? "")

        let eventLoop = group.next()
        let upgradePromise = eventLoop.makePromise(of: Void.self)

        let handler = SlackWSHandler(
            onText: { [weak self] text in self?.handleFrame(text) },
            onClose: { [weak self] in self?.wsHandler = nil }
        )

        let upgrader = NIOWebSocketClientUpgrader(upgradePipelineHandler: { channel, _ in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers([
                    NIOWebSocketFrameAggregator(
                    minNonFinalFragmentSize: 0,
                    maxAccumulatedFrameCount: 64,
                    maxAccumulatedFrameSize: 4 * 1024 * 1024
                ),
                    handler,
                ])
            }
        })

        let requestHandler = SlackUpgradeRequestHandler(path: path, host: host, appToken: appToken)

        let config = NIOHTTPClientUpgradeSendableConfiguration(
            upgraders: [upgrader],
            completionHandler: { context in
                context.pipeline.syncOperations.removeHandler(requestHandler, promise: nil)
                upgradePromise.succeed(())
            }
        )

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config)
                    .flatMap { channel.pipeline.addHandler(requestHandler) }
            }

        _ = try await bootstrap.connect(host: host, port: port).get()
        // The request handler fires the GET (with upgrade headers) on
        // channelActive; wait for the 101 + pipeline swap.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            upgradePromise.futureResult.whenComplete { result in
                switch result {
                case .success: cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
        self.wsHandler = handler
        logger.info("slack socket connected")
    }

    // MARK: - Frames

    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "hello":
            logger.debug("slack socket hello")
        case "events_api":
            ack(json)
            handleEventPayload(json["payload"] as? [String: Any])
        case "slash_commands":
            ack(json)
            handleSlashCommand(json["payload"] as? [String: Any])
        case "interactive":
            ack(json)
            // Interactive block actions (approvals) are Phase 5 scope.
        default:
            break
        }
    }

    private func ack(_ envelope: [String: Any]) {
        guard let envelopeID = envelope["envelope_id"] as? String else { return }
        let payload: [String: Any] = ["envelope_id": envelopeID]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            wsHandler?.sendText(text)
        }
    }

    private func handleEventPayload(_ payload: [String: Any]?) {
        guard let payload else { return }
        let event = payload["event"] as? [String: Any]
        let eventType = (event?["type"] as? String) ?? (payload["type"] as? String)
        if eventType == "app_mention" || eventType?.hasPrefix("message") == true {
            handleMessage(event, isMention: eventType == "app_mention")
        }
    }

    private func handleSlashCommand(_ payload: [String: Any]?) {
        guard let payload else { return }
        let user = payload["user_id"] as? String
        let channel = payload["channel_id"] as? String
        let text = payload["text"] as? String ?? ""
        guard let channel else { return }
        let target = ChatTarget(platform: "slack", chatID: channel)
        guard authz.allows(senderID: user, chat: target, isMention: true, chatType: "channel") else { return }
        continuation.yield(IncomingMessage(
            id: payload["trigger_id"] as? String ?? "slash-\(Int(Date().timeIntervalSince1970))",
            chat: target,
            text: text.isEmpty ? "/help" : text,
            senderID: user ?? "",
            senderName: nil,
            isMention: true,
            raw: nil
        ))
    }

    private func messageChatType(_ event: [String: Any]) -> String {
        if (event["channel_type"] as? String) == "im" { return "dm" }
        return "channel"
    }

    private func handleMessage(_ event: [String: Any]?, isMention: Bool) {
        guard let event else { return }
        if (event["bot_id"] as? String) != nil { return }
        if event["subtype"] as? String == "bot_message" || event["subtype"] as? String == "message_changed" { return }
        guard let channel = event["channel"] as? String,
              let text = event["text"] as? String,
              let ts = event["ts"] as? String else { return }
        let user = event["user"] as? String ?? ""
        let threadTS = event["thread_ts"] as? String
        let cleanText = stripMentions(text)
        let chatType = messageChatType(event)

        let target = ChatTarget(
            platform: "slack",
            chatID: channel,
            threadID: (threadTS != nil && threadTS != ts) ? threadTS : nil
        )
        guard authz.allows(
            senderID: user.isEmpty ? nil : user,
            chat: target,
            isMention: isMention,
            chatType: chatType
        ) else {
            logger.debug("slack: denied sender \(user) in \(channel)")
            return
        }
        continuation.yield(IncomingMessage(
            id: ts,
            chat: target,
            text: cleanText,
            senderID: user,
            senderName: event["username"] as? String,
            isReply: threadTS != nil && threadTS != ts,
            replyToID: (threadTS != nil && threadTS != ts) ? threadTS : nil,
            isMention: isMention,
            raw: nil
        ))
    }

    /// Remove `<@U123>` (and `<@U123|name>`) mentions from message text.
    private func stripMentions(_ text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "<@[A-Z0-9]+(\\|[^>]*)?>")
        var out = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(match.range, in: text) else { continue }
            out += text[last..<r.lowerBound]
            last = r.upperBound
        }
        out += text[last...]
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SlackError: Error, CustomStringConvertible {
    case apiError(String)
    case connection

    var description: String {
        switch self {
        case .apiError(let s): return "Slack API error: \(s)"
        case .connection: return "Slack socket connection failed"
        }
    }
}

/// Sends the Socket Mode GET upgrade request when the channel becomes active.
final class SlackUpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let path: String
    private let host: String
    private let appToken: String
    private var requestSent = false

    init(path: String, host: String, appToken: String) {
        self.path = path
        self.host = host
        self.appToken = appToken
    }

    func channelActive(context: ChannelHandlerContext) {
        guard !requestSent else { return }
        requestSent = true
        // The upgrader reads the request key from the pipeline; the standard
        // headers are completed by the upgrading logic when the request is
        // written through the upgrade handler (it augments on outbound).
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: path,
            headers: HTTPHeaders([
                ("Host", host),
                ("Authorization", "Bearer \(appToken)"),
            ])
        )
        context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
        let empty = context.channel.allocator.buffer(capacity: 0)
        context.write(Self.wrapOutboundOut(.body(.byteBuffer(empty))), promise: nil)
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}

/// Converts WebSocket frames into text callbacks; also the socket's send
/// path (NIO 2.100 removed the standalone `WebSocket` convenience type).
final class SlackWSHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let onText: (String) -> Void
    private let onClose: () -> Void
    private weak var context: ChannelHandlerContext? = nil

    init(onText: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onText = onText
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func sendText(_ text: String) {
        var data = context?.channel.allocator.buffer(capacity: text.utf8.count)
        data?.writeString(text)
        var frame = WebSocketFrame(fin: true, opcode: .text, data: data ?? ByteBuffer())
        context?.write(NIOAny(frame), promise: nil)
        context?.flush()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            let bytes = frame.unmaskedData
            if let text = String(bytes: bytes.readableBytesView, encoding: .utf8) {
                onText(text)
            }
        case .ping:
            frame.opcode = .pong
            context.writeAndFlush(NIOAny(frame), promise: nil)
        case .connectionClose:
            onClose()
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }

    func close() {
        context?.close(promise: nil)
    }
}
