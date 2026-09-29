import Foundation
import NIO
import Logging

/// A platform adapter for email (IMAP inbound polling + SMTP outbound).
///
/// reference email parity (text transport):
/// - polls the INBOX (IMAP) on an interval, parses RFC 822 messages
/// - delivers to the gateway per-sender "chat"; authz = sender allowlist
/// - replies over SMTP with `In-Reply-To`/`References` threading
/// - never picks up its own sent mail (sender == configured address)
///
/// Not supported: attachments, HTML-only rendering (bodies are stripped to
/// text), and streaming edits (email is send-once).
public final class EmailAdapter: PlatformAdapter {

    public let name = "email"
    public let incomingMessages: AsyncStream<IncomingMessage>

    private let config: EmailGatewayConfig
    private let group: EventLoopGroup
    private let authz: AuthzPolicy
    private let continuation: AsyncStream<IncomingMessage>.Continuation
    private let logger = Logger(label: "com.arc-agent.email-adapter")

    public init(config: EmailGatewayConfig, eventLoopGroup: EventLoopGroup? = nil) {
        self.config = config
        self.group = eventLoopGroup ?? MultiThreadedEventLoopGroup.singleton
        self.authz = AuthzPolicy(
            allowedUsers: config.allowedUsers,
            allowAllUsers: config.allowAllUsers || config.allowedUsers.isEmpty
        )
        var cont: AsyncStream<IncomingMessage>.Continuation!
        self.incomingMessages = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public let homeChannel: String? = nil

    public var canEditMessages: Bool { false }

    public func run() async throws {
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                do {
                    try await pollOnce()
                } catch {
                    logger.warning("email poll failed: \(error)")
                }
                try await Task.sleep(for: .seconds(Double(config.pollIntervalSeconds)))
            }
        } onCancel: {
            self.continuation.finish()
        }
    }

    // MARK: - Poll

    private func pollOnce() async throws {
        guard !config.imapHost.isEmpty else { return }
        let client = IMAPClient(
            host: config.imapHost,
            port: config.imapPort,
            username: config.address,
            password: config.password,
            useTLS: config.imapUseTLS,
            eventLoopGroup: group
        )
        try await client.connect()
        defer { Task { try? await client.logout() } }

        let numbers = try await client.searchUnseen()
        for number in numbers {
            guard !Task.isCancelled else { return }
            let raw: Data
            do {
                raw = try await client.fetchMessage(number)
            } catch {
                logger.warning("email fetch #\(number) failed: \(error)")
                continue
            }
            guard let parsed = EmailMessageParser.parse(raw) else {
                logger.debug("email: unparseable message #\(number)")
                continue
            }
            // Never respond to ourselves.
            let own = config.address.lowercased()
            if parsed.from == own {
                _ = try? await client.markSeen(number)
                continue
            }
            let target = ChatTarget(platform: "email", chatID: parsed.from)
            guard authz.allows(senderID: parsed.from, chat: target, isMention: true, chatType: "dm") else {
                logger.debug("email: denied sender \(parsed.from)")
                _ = try? await client.markSeen(number)
                continue
            }
            let subject = parsed.subject.isEmpty ? "(no subject)" : parsed.subject
            let body = parsed.body
            let text = body.isEmpty ? subject : subject + "\n\n" + body

            continuation.yield(IncomingMessage(
                id: parsed.messageID ?? "email-\(number)",
                chat: target,
                text: text,
                senderID: parsed.from,
                senderName: parsed.from,
                isReply: parsed.inReplyTo != nil,
                replyToID: parsed.inReplyTo,
                isMention: true,
                raw: [
                    "emailSubject": AnySendable(subject),
                    "emailMessageID": AnySendable(parsed.messageID ?? ""),
                    "emailReferences": AnySendable(parsed.references ?? ""),
                ]
            ))
            try await client.markSeen(number)
        }
    }

    // MARK: - Send

    public func send(message: OutgoingMessage, to target: ChatTarget) async throws -> SendResult {
        guard !config.smtpHost.isEmpty else { throw MailError.notConnected }
        let sender = SMTPSender(
            host: config.smtpHost,
            port: config.smtpPort,
            username: config.address,
            password: config.password,
            useTLS: config.smtpUseTLS,
            eventLoopGroup: group
        )
        try await sender.connect()
        defer { Task { try? await sender.quit() } }

        let subjectLine = message.metadata?["subject"] ?? "Re: ARC Agent"
        let inReplyTo = message.metadata?["inReplyTo"]
        let references = message.metadata?["references"]

        var headers = """
        From: \(config.address)
        To: \(target.chatID)
        Subject: \(subjectLine)
        MIME-Version: 1.0
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 8bit

        """
        if let inReplyTo {
            headers = headers.replacingOccurrences(of: "Content-Transfer-Encoding: 8bit\n\n", with: "Content-Transfer-Encoding: 8bit\nIn-Reply-To: <\(inReplyTo)>\n\n")
        }
        if let references {
            headers = headers.replacingOccurrences(of: "In-Reply-To: <\(inReplyTo ?? "")>\n\n", with: "In-Reply-To: <\(inReplyTo ?? "")>\nReferences: <\(references)>\n\n")
                .replacingOccurrences(of: "Content-Transfer-Encoding: 8bit\n\n", with: "Content-Transfer-Encoding: 8bit\nReferences: <\(references)>\n\n")
        }

        let body = EmailFormat.format(message.text)
        let full = headers + body

        try await sender.sendMail(from: config.address, to: target.chatID, message: full)
        return SendResult(messageID: nil)
    }
}
