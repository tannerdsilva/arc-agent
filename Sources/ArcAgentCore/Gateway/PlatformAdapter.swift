import Foundation
import ServiceLifecycle

/// A platform adapter connects the gateway to a messaging platform.
///
/// Each platform adapter is a ``Service`` managed by the gateway's
/// ``ServiceGroup``. It produces an ``AsyncStream`` of incoming messages
/// and provides a method to send outgoing messages back to the platform.
///
/// The tail methods (``sendTyping``, ``sendUpdate``, ``deleteMessage``,
/// ``format``, ``truncate``) have safe defaults so minimal adapters only
/// need ``send`` — richer adapters (Telegram, Slack) override the ones the
/// gateway's live-streaming path depends on.
///
/// - Note: The `start()`/`stop()` lifecycle is managed by the
///   ``Service`` protocol's `run()` method. Adapters should run their
///   polling or websocket loop in `run()` and clean up on cancellation.
public protocol PlatformAdapter: Service {
    /// Human-readable name for this adapter (e.g. "telegram", "discord").
    var name: String { get }

    /// Send a message to a chat target on this platform.
    ///
    /// Returns a ``SendResult`` carrying the platform message id (when the
    /// platform reports one) so the streaming path can later edit it.
    @discardableResult
    func send(message: OutgoingMessage, to: ChatTarget) async throws -> SendResult

    /// An async stream of incoming messages from this platform.
    ///
    /// The gateway reads from this stream to dispatch messages to agent
    /// sessions. The stream should produce messages as they arrive and
    /// terminate when the adapter is cancelled.
    var incomingMessages: AsyncStream<IncomingMessage> { get }
}

// MARK: - Optional surface (defaults keep minimal adapters small)

public extension PlatformAdapter {
    /// Whether this platform supports editing an already-sent message in
    /// place. Streaming adapters (Telegram, Slack) return `true`; pollers
    /// that cannot edit (Email) return `false` and the gateway sends the
    /// full response once.
    var canEditMessages: Bool { false }

    /// Show the platform's "typing…" indicator in the chat.
    ///
    /// The gateway calls this on a keep-alive loop while a turn is running.
    /// Default: no-op (platforms without a typing API).
    func sendTyping(to target: ChatTarget) async throws {}

    /// Replace the text of a previously sent message in place.
    ///
    /// - Parameters:
    ///   - messageID: The id returned by the matching ``send`` call.
    ///   - text: New full text for the message.
    ///   - target: Where the original message was sent.
    ///
    /// Default: throws ``GatewayError.unsupportedOperation`` — the gateway
    /// only calls this when ``canEditMessages`` is `true`.
    func sendUpdate(messageID: String, text: String, parseMode: String?, to target: ChatTarget) async throws {
        throw GatewayError.unsupportedOperation("\(name): edit_message not supported")
    }

    /// Delete a previously sent message. Default: no-op.
    func deleteMessage(messageID: String, to target: ChatTarget) async throws {}

    /// Format agent markdown for this platform's renderer.
    ///
    /// Default: identity (platforms render plain markdown natively).
    /// Telegram overrides with MarkdownV2 escaping; Slack with mrkdwn.
    func format(_ text: String) -> String { text }

    /// Split a too-long message into platform-sized chunks.
    ///
    /// Default: simple newline/space split at `maxLength`.
    func truncate(_ text: String, maxLength: Int) -> [String] {
        PlatformChunker.chunk(text, maxLength: maxLength)
    }

    /// Metadata about a chat (name/type). Default: `nil`.
    func getChatInfo(chatID: String) async throws -> ChatInfo? { nil }
}

/// Result of a successful send.
public struct SendResult: Sendable {
    /// Platform message id (nil when the platform does not report one).
    public let messageID: String?

    public init(messageID: String?) {
        self.messageID = messageID
    }
}

/// Lightweight chat metadata (Hermes `get_chat_info` parity).
public struct ChatInfo: Sendable {
    public let name: String?
    public let type: String // "dm", "group", "channel"

    public init(name: String?, type: String) {
        self.name = name
        self.type = type
    }
}
