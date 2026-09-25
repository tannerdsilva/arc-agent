import Foundation

/// Authorization policy for one platform (Hermes allowlist parity).
///
/// Semantics:
/// - `allowAllUsers == true` → any sender may talk to the bot.
/// - otherwise the sender id must be in `allowedUsers` (when non-empty).
/// - `allowedChats == nil` → all chats allowed; otherwise the chat id (or
///   thread key) must be listed.
/// - `requireMention == true` → in group/channel chats the message must
///   mention the bot (the flag is ORed with the message being a DM).
public struct AuthzPolicy: Sendable, Equatable {
    /// Comma-separable list of permitted senders (platform user ids).
    public var allowedUsers: Set<String>
    /// Allow any user (dev convenience; Hermes ALLOW_ALL_USERS parity).
    public var allowAllUsers: Bool
    /// Chat ids permitted; `nil` = every chat (plugin default: per-user).
    public var allowedChats: Set<String>?
    /// Whether messages must @-mention the bot outside DMs.
    public var requireMention: Bool

    public init(
        allowedUsers: Set<String> = [],
        allowAllUsers: Bool = false,
        allowedChats: Set<String>? = nil,
        requireMention: Bool = false
    ) {
        self.allowedUsers = allowedUsers
        self.allowAllUsers = allowAllUsers
        self.allowedChats = allowedChats
        self.requireMention = requireMention
    }

    /// The policy that allows everything (default when no gate configured).
    public static let permissive = AuthzPolicy(allowAllUsers: true)

    /// Parse a comma-separated id list (Hermes `<PLATFORM>_ALLOWED_USERS`).
    public static func parseIds(_ raw: String?) -> Set<String> {
        Set((raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Decide whether an inbound message is authorized.
    ///
    /// - Parameters:
    ///   - senderID: Platform user id of the sender.
    ///   - chat: The chat the message arrived in.
    ///   - isMention: Whether the message mentions the bot (adapter supplies).
    ///   - chatType: "dm", "group" or "channel" when known (default nil).
    public func allows(senderID: String?, chat: ChatTarget, isMention: Bool, chatType: String? = nil) -> Bool {
        // Sender gate.
        if !allowAllUsers {
            guard let senderID, allowedUsers.contains(senderID) else { return false }
        }
        // Chat gate (match on chat id; thread-scoped chats also match their
        // parent channel — hierarchical matching).
        if let allowedChats {
            let inList = allowedChats.contains(chat.chatID)
                || (chat.parentChatID.map { allowedChats.contains($0) } ?? false)
            if !inList { return false }
        }
        // Mention gate: outside DMs the bot must be mentioned.
        if requireMention, chatType != "dm", !isMention {
            return false
        }
        return true
    }
}
