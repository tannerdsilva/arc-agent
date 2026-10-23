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

/// A streaming delta published by a session host so a guest tunnel can paint
/// the owner's reply live (kind 3008, `d` tag `arc/stream/<sessionID>/<seq>`).
///
/// Each event is an incremental text chunk; `final` marks the end of a
/// response, after which the guest swaps the live block for the committed
/// kind-3001 message.
public struct TesseraStreamDelta: Codable, Sendable, Equatable {
    /// The global sequence number of this delta event.
    public var seq: Int
    /// The session this delta belongs to.
    public var sessionID: String
    /// The seq of the committed kind-3001 message this streams toward.
    public var messageSeq: Int
    /// The incremental text chunk appended to the guest's live block.
    public var text: String
    /// True when the response is complete (the committed 3001 landed).
    public var final: Bool
    /// The host (owner) identity that produced this stream.
    public var owner: String

    public init(seq: Int, sessionID: String, messageSeq: Int, text: String, final: Bool, owner: String) {
        self.seq = seq
        self.sessionID = sessionID
        self.messageSeq = messageSeq
        self.text = text
        self.final = final
        self.owner = owner
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
    /// First user message (truncated), or a generated title — lets UIs show
    /// conversation titles from list summaries without loading messages.
    /// Older records without this field decode as nil.
    public var titleHint: String?
    /// Optional pinned model/config snapshot (shared sessions).
    public var config: SessionConfigSnapshot?
    /// The signing identity that owns this session (nil = legacy/current).
    public var owner: String?

    public init(seq: Int, sessionID: String, createdAt: Date, updatedAt: Date,
                model: String, provider: String, messageCount: Int, totalTokens: Int,
                titleHint: String? = nil, config: SessionConfigSnapshot? = nil,
                owner: String? = nil) {
        self.seq = seq
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.provider = provider
        self.messageCount = messageCount
        self.totalTokens = totalTokens
        self.titleHint = titleHint
        self.config = config
        self.owner = owner
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
        let identity = await connection.nostrPublicKeyString
        let grants = await TesseraShareStore.shared.latestGrants()
        guard isVisible(meta, identity: identity, grants: grants) else { return nil }
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
        // Self-healing metadata: historical appends could leave messageCount
        // ahead of the real event count (or titleHint unset for legacy
        // records); republish a corrected meta — same updatedAt, so the
        // sidebar ordering is untouched — once, on the next open.
        let hinted = meta.titleHint
            ?? pairs.first(where: { $0.message.role == .user })?.message.content.map { String($0.prefix(120)) }
        if pairs.count != meta.messageCount || hinted != meta.titleHint {
            let corrected = TesseraSessionMeta(
                seq: await conn.takeSequence(), sessionID: id,
                createdAt: meta.createdAt, updatedAt: meta.updatedAt,
                model: meta.model, provider: meta.provider,
                messageCount: pairs.count, totalTokens: meta.totalTokens,
                titleHint: hinted, config: meta.config, owner: meta.owner
            )
            try await publish(meta: corrected)
        }
        return Session(
            id: id,
            createdAt: meta.createdAt,
            updatedAt: meta.updatedAt,
            model: meta.model,
            provider: meta.provider,
            title: hinted,
            messageCount: pairs.count,
            messages: pairs.map(\.message),
            config: meta.config,
            owner: meta.owner
        )
    }

    public func update(_ session: Session) async throws {
        let conn = connection
        try await conn.ensureStarted()
        let identity = await conn.nostrPublicKeyString
        let grants = await TesseraShareStore.shared.latestGrants()
        let storedOwner = await latestMeta(for: session.id)?.owner
        // Refuse to resurrect: a session with no local metadata that claims a
        // foreign owner was deleted by its host — re-publishing meta here is
        // exactly what brought deleted sessions back from the dead on a
        // sharee. (The host's own update path always has meta, published by
        // create() and visible via publish-time indexing of pendings.)
        if let foreign = session.owner, foreign != identity, storedOwner == nil {
            throw SessionShareError.notAuthorized
        }
        guard SharedSessionACL.canContribute(
            identity: identity ?? "", sessionID: session.id,
            sessionOwner: storedOwner ?? session.owner, grants: grants
        ) else {
            throw SessionShareError.notAuthorized
        }
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
        // Purge every record kind tied to the session, so the delete is
        // authoritative for both host and sharee: messages, metadata,
        // streaming deltas, and the share grants (a surviving grant or meta
        // event re-lists the session in the other instance's web UI).
        try await conn.deleteAll(dTagPrefix: "arc/s/\(id)/", kind: TesseraConnection.messageKind)
        try await conn.deleteAll(dTagPrefix: "arc/meta/\(id)/", kind: TesseraConnection.metadataKind)
        try await conn.deleteAll(dTagPrefix: "arc/stream/\(id)/", kind: TesseraConnection.streamKind)
        try await conn.deleteAll(dTagPrefix: "arc/share/\(id)/", kind: TesseraConnection.shareKind)
    }

    public func list(limit: Int, offset: Int) async throws -> [Session] {
        let conn = connection
        try await conn.ensureStarted()
        let metas = await latestMetaGrouped()
        let identity = await connection.nostrPublicKeyString
        let grants = await TesseraShareStore.shared.latestGrants()
        let visible = metas.values.filter { isVisible($0, identity: identity, grants: grants) }
        let ordered = visible.sorted { $0.updatedAt > $1.updatedAt }
        let page = ordered.dropFirst(max(0, offset)).prefix(limit)
        // Metadata-only summaries: message bodies are materialized lazily via
        // get(id:) when a chat is opened (bounded memory at very large scale).
        return page.map { meta in
            Session(
                id: meta.sessionID,
                createdAt: meta.createdAt,
                updatedAt: meta.updatedAt,
                model: meta.model,
                provider: meta.provider,
                title: meta.titleHint,
                messageCount: meta.messageCount
            )
        }
    }

    public func appendMessage(sessionID: String, message: Message) async throws {
        let conn = connection
        try await conn.ensureStarted()
        let identity = await conn.nostrPublicKeyString
        let grants = await TesseraShareStore.shared.latestGrants()
        let owner = await latestMeta(for: sessionID)?.owner
        guard SharedSessionACL.canContribute(
            identity: identity ?? "", sessionID: sessionID, sessionOwner: owner, grants: grants
        ) else {
            throw SessionShareError.notAuthorized
        }
        try await publishMessage(message, sessionID: sessionID)
        if let meta = await latestMeta(for: sessionID) {
            var hint = meta.titleHint
            if hint == nil, message.role == .user,
               let c = message.content, !c.isEmpty {
                hint = String(c.prefix(120))
            }
            let updated = TesseraSessionMeta(
                seq: await conn.takeSequence(), sessionID: meta.sessionID,
                createdAt: meta.createdAt, updatedAt: Date(),
                model: meta.model, provider: meta.provider,
                messageCount: meta.messageCount + 1, totalTokens: meta.totalTokens,
                titleHint: hint, config: meta.config, owner: meta.owner
            )
            try await publish(meta: updated)
        }
    }

    /// Whether this metadata is visible to the current identity. When the
    /// connection has no determined identity (not started / no key) sharing is
    /// not in effect and everything is visible (legacy single-user behaviour).
    private func isVisible(_ meta: TesseraSessionMeta, identity: String?, grants: [TesseraShareGrant]) -> Bool {
        guard let identity, !identity.isEmpty else { return true }
        return SharedSessionACL.isVisible(
            identity: identity, sessionID: meta.sessionID,
            sessionOwner: meta.owner, grants: grants
        )
    }

    // MARK: - Private

    private func publishMeta(from session: Session, messageCount: Int) async throws {
        let defaultOwner = await connection.nostrPublicKeyString
        let owner = session.owner ?? defaultOwner
        let meta = TesseraSessionMeta(
            seq: await connection.takeSequence(), sessionID: session.id,
            createdAt: session.createdAt, updatedAt: session.updatedAt,
            model: session.model, provider: session.provider,
            messageCount: messageCount, totalTokens: 0,
            titleHint: metaTitleHint(session: session),
            config: session.config,
            owner: owner
        )
        try await publish(meta: meta)
    }

    /// Title hint for a session summary: the explicit title if set, otherwise
    /// the first user message (truncated). Never empty.
    private func metaTitleHint(session: Session) -> String? {
        if let t = session.title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(t.prefix(120))
        }
        guard let first = session.messages.first(where: { $0.role == .user }),
              let c = first.content, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return String(c.prefix(120))
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
        // O(1): the connection keeps the newest metadata record per session
        // group (d-tag `arc/meta/<session>/<seq>`); no more full-store scan +
        // decode-of-every-meta per append.
        guard let record = await connection.latestRecord(groupKey: "arc/meta/\(sessionID)") else {
            return nil
        }
        return try? JSONDecoder().decode(TesseraSessionMeta.self, from: Data(record.content.utf8))
    }

    /// The newest metadata record per session.
    private func latestMetaGrouped() async -> [String: TesseraSessionMeta] {
        // O(#sessions): one record per group (the connection's "latest per
        // d-tag group" index), decoded here — instead of decoding every
        // metadata event in the store on every list.
        var best: [String: TesseraSessionMeta] = [:]
        let groups = await connection.latestGroups(prefix: "arc/meta/")
        for (group, record) in groups {
            let sid = String(group.dropFirst("arc/meta/".count))
            guard let meta = try? JSONDecoder().decode(TesseraSessionMeta.self, from: Data(record.content.utf8)) else {
                continue
            }
            if let existing = best[sid], existing.seq > meta.seq { continue }
            best[sid] = meta
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
