import Foundation

/// Routes incoming messages to the appropriate agent session.
///
/// The session router maps platform chat targets to session identifiers.
/// It maintains a persistent mapping so that messages from the same chat
/// always reach the same session.
public actor SessionRouter {
    private var chatToSession: [String: String] = [:]
    private var sessionToChat: [String: ChatTarget] = [:]

    public init() {}

    /// Resolve a chat target to a **deterministic** session ID: the routing
    /// key itself (`platform:chatID:threadID`). Deterministic means a chat
    /// always maps to the same session across restarts (the gateway derives
    /// session IDs this way); the key stays the durable binding and the
    /// reverse map is maintained for ``chatTarget(for:)``.
    public func resolve(chat: ChatTarget) -> String {
        let key = routingKey(for: chat)
        if chatToSession[key] == nil {
            chatToSession[key] = key
            sessionToChat[key] = chat
        }
        return key
    }

    /// Get the chat target for a session, if known.
    public func chatTarget(for sessionID: String) -> ChatTarget? {
        sessionToChat[sessionID]
    }

    /// Remove a session's routing information.
    public func remove(sessionID: String) {
        sessionToChat.removeValue(forKey: sessionID)
        let keysToRemove = chatToSession.filter { $0.value == sessionID }.map(\.key)
        for key in keysToRemove {
            chatToSession.removeValue(forKey: key)
        }
    }

    // MARK: - Private

    private func routingKey(for chat: ChatTarget) -> String {
        if let threadID = chat.threadID {
            return "\(chat.platform):\(chat.chatID):\(threadID)"
        }
        return "\(chat.platform):\(chat.chatID)"
    }
}
