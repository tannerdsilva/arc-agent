import Foundation

/// An in-memory ``SessionStore`` used by delegation children (and tests).
///
/// Children never persist to the parent's store: their transcripts are
/// inspectable through this store for the lifetime of the agent but vanish
/// with the process. Conforms to ``SessionStore`` with the same summary
/// semantics: `list` returns metadata-only sessions.
public actor VolatileSessionStore: SessionStore {

    private var sessions: [String: Session] = [:]

    public init() {}

    public func create(_ session: Session) async throws {
        sessions[session.id] = session
    }

    public func get(id: String) async throws -> Session? {
        sessions[id]
    }

    public func update(_ session: Session) async throws {
        sessions[session.id] = session
    }

    public func delete(id: String) async throws {
        sessions[id] = nil
    }

    public func list(limit: Int, offset: Int) async throws -> [Session] {
        let sorted = sessions.values.sorted { $0.updatedAt > $1.updatedAt }
        return Array(sorted.dropFirst(max(0, offset)).prefix(max(0, limit))).map { summary in
            var s = summary
            s.messages = []
            s.messageCount = summary.messages.count
            return s
        }
    }

    public func appendMessage(sessionID: String, message: Message) async throws {
        var session = sessions[sessionID] ?? Session(id: sessionID)
        session.messages.append(message)
        session.updatedAt = Date()
        sessions[sessionID] = session
    }
}
