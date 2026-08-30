import Foundation

/// A chat target identifies where to deliver an outgoing message.
///
/// Each platform adapter interprets these fields according to its own
/// addressing scheme. For Telegram, `chatID` is the chat ID and
/// `threadID` is the message thread ID (topics). For Discord,
/// `chatID` is the channel ID.
public struct ChatTarget: Sendable, Codable, Hashable {
    /// Platform identifier (e.g. "telegram", "discord", "slack", "api").
    public let platform: String
    /// Platform-specific chat/channel/user identifier.
    public let chatID: String
    /// Optional thread/topic identifier within the chat.
    public let threadID: String?

    public init(platform: String, chatID: String, threadID: String? = nil) {
        self.platform = platform
        self.chatID = chatID
        self.threadID = threadID
    }
}

/// An incoming message from a platform adapter.
///
/// The gateway receives these from platform adapters and routes them to
/// the appropriate agent session.
public struct IncomingMessage: Sendable {
    /// Unique message identifier (platform-specific).
    public let id: String
    /// The chat this message came from.
    public let chat: ChatTarget
    /// The text content of the message.
    public let text: String
    /// The sender's user identifier (platform-specific).
    public let senderID: String
    /// The sender's display name, if available.
    public let senderName: String?
    /// Whether this message is a reply to a previous agent message.
    public let isReply: Bool
    /// The message ID this is replying to, if applicable.
    public let replyToID: String?
    /// Raw platform-specific metadata.
    public let raw: [String: AnySendable]?

    public init(
        id: String,
        chat: ChatTarget,
        text: String,
        senderID: String,
        senderName: String? = nil,
        isReply: Bool = false,
        replyToID: String? = nil,
        raw: [String: AnySendable]? = nil
    ) {
        self.id = id
        self.chat = chat
        self.text = text
        self.senderID = senderID
        self.senderName = senderName
        self.isReply = isReply
        self.replyToID = replyToID
        self.raw = raw
    }
}

/// An outgoing message to be delivered through a platform adapter.
public struct OutgoingMessage: Sendable {
    /// The text content to send.
    public let text: String
    /// Optional parse mode (e.g. "markdown", "html").
    public let parseMode: String?
    /// Whether this is a partial/progress update (not a final response).
    public let isPartial: Bool
    /// Optional attachments (file URLs or data references).
    public let attachments: [Attachment]?

    public struct Attachment: Sendable {
        public let filename: String
        public let url: String
        public let mimeType: String?

        public init(filename: String, url: String, mimeType: String? = nil) {
            self.filename = filename
            self.url = url
            self.mimeType = mimeType
        }
    }

    public init(
        text: String,
        parseMode: String? = "markdown",
        isPartial: Bool = false,
        attachments: [Attachment]? = nil
    ) {
        self.text = text
        self.parseMode = parseMode
        self.isPartial = isPartial
        self.attachments = attachments
    }
}

/// A type-erased sendable value for platform-specific metadata.
///
/// Holds any ``Sendable`` value. Built-in value types (strings, numbers,
/// `Data`) cover every current producer; there is no unchecked cast.
public struct AnySendable: Sendable {
    public let value: any Sendable

    public init(_ value: some Sendable) { self.value = value }
}
