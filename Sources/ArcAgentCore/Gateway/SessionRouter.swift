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

    /// Resolve a chat target to a session ID, creating one if needed.
    public func resolve(chat: ChatTarget) -> String {
        let key = routingKey(for: chat)
        if let existing = chatToSession[key] {
            return existing
        }
        let sessionID = UUID().uuidString
        chatToSession[key] = sessionID
        sessionToChat[sessionID] = chat
        return sessionID
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
