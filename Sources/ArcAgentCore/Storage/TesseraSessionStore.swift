import Foundation

/// A session message persisted as a Tessera event (kind 3001).
///
/// The payload is JSON-encoded into the event content; the event's `d` tag
/// carries `arc/s/<sessionID>/<seq>`.
public struct TesseraStoredMessage: Codable, Sendable, Equatable {
    /// The global sequence number of this event.
    public var seq: Int
    /// The session this message belongs to.
    public var sessionID: String
    /// The message payload.
    public var message: Message

    public init(seq: Int, sessionID: String, message: Message) {
        self.seq = seq
        self.sessionID = sessionID
        self.message = message
    }
}

/// Session metadata persisted as a Tessera event (kind 3003).
///
/// Metadata is append-only (like messages); the newest record for a session,
/// selected client-side by sequence number, is the current one.
public struct TesseraSessionMeta: Codable, Sendable, Equatable {
    /// The global sequence number of this event.
    public var seq: Int
    /// The session this metadata belongs to.
    public var sessionID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String
    public var provider: String
    public var messageCount: Int
    public var totalTokens: Int

    public init(seq: Int, sessionID: String, createdAt: Date, updatedAt: Date,
                model: String, provider: String, messageCount: Int, totalTokens: Int) {
        self.seq = seq
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.provider = provider
        self.messageCount = messageCount
        self.totalTokens = totalTokens
    }
}

/// A ``SessionStore`` backed by a Tessera server.
///
/// Sessions are stored as signed NOSTR events through the shared
/// ``TesseraConnection``:
///
/// - Messages: kind 3001, `d` tag `arc/s/<sessionID>/<seq>`
/// - Metadata: kind 3003, `d` tag `arc/meta/<sessionID>/<seq>`
///
/// The connection is shared process-wide, so every session agent of every
/// profile writes into the same Tessera application namespace.
public actor TesseraSessionStore: SessionStore {

    /// Create a session store against the shared Tessera connection.
    public init() {}

    private var connection: TesseraConnection { TesseraConnection.shared }

    // MARK: - SessionStore

    public func create(_ session: Session) async throws {
        let conn = connection
        try await conn.ensureStarted()
        try await publishMeta(from: session, messageCount: session.messages.count)
        for message in session.messages {
            try await publishMessage(message, sessionID: session.id)
        }
    }

    public func get(id: String) async throws -> Session? {
        let conn = connection
        try await conn.ensureStarted()
        guard let meta = await latestMeta(for: id) else { return nil }
        var pairs: [(seq: Int, message: Message)] = []
        for record in await conn.snapshot(kind: TesseraConnection.messageKind)
            .filter({ $0.dTag?.hasPrefix("arc/s/\(id)/") ?? false }) {
            guard let stored = try? JSONDecoder().decode(TesseraStoredMessage.self, from: Data(record.content.utf8)),
                  stored.sessionID == id else {
                continue
            }
            pairs.append((stored.seq, stored.message))
        }
        pairs.sort { $0.seq < $1.seq }
        return Session(
            id: id,
            createdAt: meta.createdAt,
            updatedAt: meta.updatedAt,
            model: meta.model,
            provider: meta.provider,
            messages: pairs.map(\.message)
        )
    }

    public func update(_ session: Session) async throws {
        let conn = connection
        try await conn.ensureStarted()
        try await publishMeta(from: session, messageCount: session.messages.count)
        // The append-only log cannot rewrite history; publish only the
        // messages whose exact payload is not already stored.
        let existing = await storedMessages(sessionID: session.id)
        for message in session.messages {
            if existing.contains(message) { continue }
            try await publishMessage(message, sessionID: session.id)
        }
    }

    public func delete(id: String) async throws {
        let conn = connection
        try await conn.ensureStarted()
        try await conn.deleteAll(dTagPrefix: "arc/s/\(id)/", kind: TesseraConnection.messageKind)
        try await conn.deleteAll(dTagPrefix: "arc/meta/\(id)/", kind: TesseraConnection.metadataKind)
    }

    public func list(limit: Int) async throws -> [Session] {
        let conn = connection
        try await conn.ensureStarted()
        let metas = await latestMetaGrouped()
        let ordered = metas.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit)
        var sessions: [Session] = []
        for meta in ordered {
            if let s = try await get(id: meta.sessionID) {
                sessions.append(s)
            }
        }
        return sessions
    }

    public func appendMessage(sessionID: String, message: Message) async throws {
        let conn = connection
        try await conn.ensureStarted()
        try await publishMessage(message, sessionID: sessionID)
        if var meta = await latestMeta(for: sessionID) {
            let updated = TesseraSessionMeta(
                seq: await conn.takeSequence(), sessionID: meta.sessionID,
                createdAt: meta.createdAt, updatedAt: Date(),
                model: meta.model, provider: meta.provider,
                messageCount: meta.messageCount + 1, totalTokens: meta.totalTokens
            )
            try await publish(meta: updated)
        }
    }

    // MARK: - Private

    private func publishMeta(from session: Session, messageCount: Int) async throws {
        let meta = TesseraSessionMeta(
            seq: await connection.takeSequence(), sessionID: session.id,
            createdAt: session.createdAt, updatedAt: session.updatedAt,
            model: session.model, provider: session.provider,
            messageCount: messageCount, totalTokens: 0
        )
        try await publish(meta: meta)
    }

    private func publish(meta: TesseraSessionMeta) async throws {
        let content = String(decoding: try JSONEncoder().encode(meta), as: UTF8.self)
        try await connection.publish(
            kind: TesseraConnection.metadataKind,
            dTagValue: "arc/meta/\(meta.sessionID)/\(meta.seq)",
            content: content
        )
    }

    private func publishMessage(_ message: Message, sessionID: String) async throws {
        let stored = TesseraStoredMessage(seq: await connection.takeSequence(), sessionID: sessionID, message: message)
        let content = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        try await connection.publish(
            kind: TesseraConnection.messageKind,
            dTagValue: "arc/s/\(sessionID)/\(stored.seq)",
            content: content
        )
    }

    /// The newest metadata record for one session, or nil.
    private func latestMeta(for sessionID: String) async -> TesseraSessionMeta? {
        let prefix = "arc/meta/\(sessionID)/"
        var best: TesseraSessionMeta?
        for record in await connection.snapshot(kind: TesseraConnection.metadataKind)
            .filter({ $0.dTag?.hasPrefix(prefix) ?? false }) {
            guard let meta = try? JSONDecoder().decode(TesseraSessionMeta.self, from: Data(record.content.utf8)),
                  meta.sessionID == sessionID else {
                continue
            }
            if best == nil || meta.seq > best!.seq { best = meta }
        }
        return best
    }

    /// The newest metadata record per session.
    private func latestMetaGrouped() async -> [String: TesseraSessionMeta] {
        var best: [String: TesseraSessionMeta] = [:]
        for record in await connection.snapshot(kind: TesseraConnection.metadataKind) {
            guard let meta = try? JSONDecoder().decode(TesseraSessionMeta.self, from: Data(record.content.utf8)) else {
                continue
            }
            if let existing = best[meta.sessionID], existing.seq > meta.seq { continue }
            best[meta.sessionID] = meta
        }
        return best
    }

    /// The messages already stored for a session (for idempotent `update`).
    private func storedMessages(sessionID: String) async -> [Message] {
        var stored: [Message] = []
        for record in await connection.snapshot(kind: TesseraConnection.messageKind)
            .filter({ $0.dTag?.hasPrefix("arc/s/\(sessionID)/") ?? false }) {
            guard let decoded = try? JSONDecoder().decode(TesseraStoredMessage.self, from: Data(record.content.utf8)),
                  decoded.sessionID == sessionID else {
                continue
            }
            stored.append(decoded.message)
        }
        return stored
    }
}
