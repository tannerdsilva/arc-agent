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
    /// Terminal state: the host deleted this session. Published once by the
    /// owner in its final meta record; the record itself stays on the relay
    /// (it cannot be tombstoned by anyone but the host), and each sharee's
    /// client dismisses it locally once the sharee deletes their side.
    /// Older records without this field decode as nil (not deleted).
    public var deleted: Bool?

    public init(seq: Int, sessionID: String, createdAt: Date, updatedAt: Date,
                model: String, provider: String, messageCount: Int, totalTokens: Int,
                titleHint: String? = nil, config: SessionConfigSnapshot? = nil,
                owner: String? = nil, deleted: Bool? = nil) {
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
        self.deleted = deleted
    }
}

/// A sharee's "I deleted my side" notice (kind 3010,
/// `d` tag `arc/left/<sessionID>/<writer>/<n>`).
///
/// Authored by the sharee; the host surfaces it as "left the session" and
/// the sharee's own client uses it as the persistent local-dismissal marker
/// for the session (no client-side state needed — the record is the state).
public struct TesseraLeaveNotice: Codable, Sendable, Equatable {
    /// The shared session the writer severed their side of.
    public var sessionID: String
    /// The writer token (base64url of the sharee's NOSTR public key).
    public var writer: String
    /// When the sharee deleted their side.
    public var at: Date

    public init(sessionID: String, writer: String, at: Date) {
        self.sessionID = sessionID
        self.writer = writer
        self.at = at
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
        let namespaced = await writerNamespacing(for: session.id, owner: session.owner)
        for message in session.messages {
            try await publishMessage(message, sessionID: session.id, namespaced: namespaced)
        }
    }

    public func get(id: String) async throws -> Session? {
        let conn = connection
        try await conn.ensureStarted()
        guard let meta = await latestMeta(for: id) else { return nil }
        let identity = await connection.nostrPublicKeyString
        let grants = await TesseraShareStore.shared.latestGrants()
        // A sharee who deleted their side sees nothing: the leave notice they
        // published is the persistent local-dismissal marker (it survives
        // restarts and stays off the view without any client-side state).
        if let identity, !identity.isEmpty,
           await leaveNoticeSessionIDs(identity: identity).contains(id) {
            return nil
        }
        guard isVisible(meta, identity: identity, grants: grants) else { return nil }
        var pairs: [(seq: Int, namespaced: Bool, message: Message)] = []
        for record in await conn.snapshot(kind: TesseraConnection.messageKind)
            .filter({ $0.dTag?.hasPrefix("arc/s/\(id)/") ?? false }) {
            guard let stored = try? JSONDecoder().decode(TesseraStoredMessage.self, from: Data(record.content.utf8)),
                  stored.sessionID == id else {
                continue
            }
            let namespaced = record.dTag.map(TesseraConnection.isWriterNamespaced) ?? false
            pairs.append((stored.seq, namespaced, stored.message))
        }
        // Legacy sessions (all records in the global-sequence format) order
        // by their sequence numbers exactly as before. Sessions containing
        // per-writer records order by message timestamp with the per-writer
        // sequence as tiebreak — per-writer numbers are not comparable
        // across writers, and timestamps are the order the participants saw.
        let anyNamespaced = pairs.contains(where: \.namespaced)
        if anyNamespaced {
            pairs.sort { left, right in
                let l = left.message.createdAt ?? .distantPast
                let r = right.message.createdAt ?? .distantPast
                if l != r { return l < r }
                return left.seq < right.seq
            }
        } else {
            pairs.sort { $0.seq < $1.seq }
        }
        // Self-healing metadata: historical appends could leave messageCount
        // ahead of the real event count (or titleHint unset for legacy
        // records); republish a corrected meta — same updatedAt, so the
        // sidebar ordering is untouched — once, on the next open. Never on a
        // deleted session: the terminal record is the last word.
        let hinted = meta.titleHint
            ?? pairs.first(where: { $0.message.role == .user })?.message.content.map { String($0.prefix(120)) }
        if meta.deleted != true,
           pairs.count != meta.messageCount || hinted != meta.titleHint {
            let corrected = TesseraSessionMeta(
                seq: await conn.takeSequence(), sessionID: id,
                createdAt: meta.createdAt, updatedAt: meta.updatedAt,
                model: meta.model, provider: meta.provider,
                messageCount: pairs.count, totalTokens: meta.totalTokens,
                titleHint: hinted, config: meta.config, owner: meta.owner,
                deleted: meta.deleted
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
            owner: meta.owner,
            deleted: meta.deleted == true ? true : nil
        )
    }

    public func update(_ session: Session) async throws {
        let conn = connection
        try await conn.ensureStarted()
        let identity = await conn.nostrPublicKeyString
        let grants = await TesseraShareStore.shared.latestGrants()
        let latest = await latestMeta(for: session.id)
        let storedOwner = latest?.owner
        // Refuse to resurrect: a session with no local metadata that claims a
        // foreign owner was deleted by its host — re-publishing meta here is
        // exactly what brought deleted sessions back from the dead on a
        // sharee. (The host's own update path always has meta, published by
        // create() and visible via publish-time indexing of pendings.)
        if let foreign = session.owner, foreign != identity, storedOwner == nil {
            throw SessionShareError.notAuthorized
        }
        // Terminal state: a host delete tombstones its side and publishes the
        // terminal record; nothing may write to the session afterwards.
        if latest?.deleted == true {
            throw SessionShareError.sessionDeleted
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
        let namespaced = await writerNamespacing(for: session.id, owner: storedOwner ?? session.owner)
        for message in session.messages {
            if existing.contains(message) { continue }
            try await publishMessage(message, sessionID: session.id, namespaced: namespaced)
        }
    }

    /// Delete a session with role-aware semantics:
    ///
    /// - **Legacy / unshared**: purge every record kind tied to the session
    ///   (the pre-existing authoritative delete).
    /// - **Host of a shared session**: publish the terminal `deleted` meta
    ///   (the last word — it survives the tombstones), then tombstone only
    ///   host-authored events. The sharee keeps their own messages and sees
    ///   the "deleted by host" state; the relay would reject tombstones for
    ///   events the host did not author anyway.
    /// - **Sharee**: tombstone their own messages and metas, and publish a
    ///   leave notice. The host's events cannot be tombstoned (not ours)
    ///   and stay on the relay; the leave notice hides the session locally
    ///   and tells the host the grantee severed their side.
    public func delete(id: String) async throws {
        let conn = connection
        try await conn.ensureStarted()
        let identity = await conn.nostrPublicKeyString
        let meta = await latestMeta(for: id)
        let owner = meta?.owner
        let isSharee = identity != nil && !identity!.isEmpty && owner != nil && owner != identity
        let isHost = identity != nil && !identity!.isEmpty && owner != nil && owner == identity
        guard isSharee || isHost else {
            // Legacy full purge, unchanged.
            try await conn.deleteAll(dTagPrefix: "arc/s/\(id)/", kind: TesseraConnection.messageKind)
            try await conn.deleteAll(dTagPrefix: "arc/meta/\(id)/", kind: TesseraConnection.metadataKind)
            try await conn.deleteAll(dTagPrefix: "arc/stream/\(id)/", kind: TesseraConnection.streamKind)
            try await conn.deleteAll(dTagPrefix: "arc/share/\(id)/", kind: TesseraConnection.shareKind)
            return
        }
        guard let identity else { return }
        if isHost {
            try await conn.deleteAll(dTagPrefix: "arc/s/\(id)/", kind: TesseraConnection.messageKind, author: identity)
            try await conn.deleteAll(dTagPrefix: "arc/meta/\(id)/", kind: TesseraConnection.metadataKind, author: identity)
            try await conn.deleteAll(dTagPrefix: "arc/stream/\(id)/", kind: TesseraConnection.streamKind, author: identity)
            try await conn.deleteAll(dTagPrefix: "arc/share/\(id)/", kind: TesseraConnection.shareKind)
            // Terminal record LAST so the tombstone sweeps above cannot
            // touch it: this meta is the sharee's "deleted by host" signal.
            if var terminal = meta {
                terminal.seq = await conn.takeSequence()
                terminal.deleted = true
                try await publish(meta: terminal)
            }
        } else {
            try await conn.deleteAll(dTagPrefix: "arc/s/\(id)/", kind: TesseraConnection.messageKind, author: identity)
            try await conn.deleteAll(dTagPrefix: "arc/meta/\(id)/", kind: TesseraConnection.metadataKind, author: identity)
            try await publishLeaveNotice(sessionID: id)
        }
    }

    public func list(limit: Int, offset: Int) async throws -> [Session] {
        let conn = connection
        try await conn.ensureStarted()
        let metas = await latestMetaGrouped()
        let identity = await connection.nostrPublicKeyString
        let grants = await TesseraShareStore.shared.latestGrants()
        var dismissed: Set<String> = []
        if let identity, !identity.isEmpty {
            dismissed = await leaveNoticeSessionIDs(identity: identity)
        }
        // A terminal `deleted` meta is visible to sharees (it drives the
        // "deleted by host" banner) but never to its owner: the host deleted
        // the session, so it must not reappear in their sidebar — neither on
        // the next reload nor via the web UI's ghost-tolerance cache.
        let visible = metas.values.filter {
            !dismissed.contains($0.sessionID)
                && isVisible($0, identity: identity, grants: grants)
                && !($0.deleted == true && identity != nil && $0.owner == identity)
        }
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
                messageCount: meta.messageCount,
                config: meta.config,
                owner: meta.owner,
                deleted: meta.deleted == true ? true : nil
            )
        }
    }

    public func appendMessage(sessionID: String, message: Message) async throws {
        let conn = connection
        try await conn.ensureStarted()
        let identity = await conn.nostrPublicKeyString
        let grants = await TesseraShareStore.shared.latestGrants()
        let meta = await latestMeta(for: sessionID)
        let owner = meta?.owner
        // Terminal state: the host deleted this session; nothing more may be
        // written, not even the sharee's own messages.
        if meta?.deleted == true {
            throw SessionShareError.sessionDeleted
        }
        guard SharedSessionACL.canContribute(
            identity: identity ?? "", sessionID: sessionID, sessionOwner: owner, grants: grants
        ) else {
            throw SessionShareError.notAuthorized
        }
        let namespaced = await writerNamespacing(for: sessionID, owner: owner)
        try await publishMessage(message, sessionID: sessionID, namespaced: namespaced)
        if var latest = meta {
            var hint = latest.titleHint
            if hint == nil, message.role == .user,
               let c = message.content, !c.isEmpty {
                hint = String(c.prefix(120))
            }
            latest.seq = await conn.takeSequence()
            latest.updatedAt = Date()
            latest.messageCount += 1
            latest.titleHint = hint
            try await publish(meta: latest)
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

    /// Whether messages for this session must use per-writer d-tag
    /// namespaces: true exactly when more than one identity writes it —
    /// a foreign owner (we are the sharee) or our own ownership with a
    /// live grant for this session (we are the host). Single-writer
    /// sessions keep the legacy global-sequence d-tag format.
    private func writerNamespacing(for sessionID: String, owner: String?) async -> Bool {
        guard let identity = await connection.nostrPublicKeyString, !identity.isEmpty else {
            return false
        }
        if let owner, owner != identity { return true } // sharee side
        guard let owner, owner == identity else { return false } // legacy/nil
        let grants = await TesseraShareStore.shared.latestGrants()
        return grants.contains { $0.sessionID == sessionID && !$0.grantees.isEmpty }
    }

    /// Publish one chat message. `namespaced` selects the d-tag format:
    /// `arc/s/<sid>/<writer>/<n>` (per-writer counter, collision-free for
    /// shared sessions) or the legacy `arc/s/<sid>/<seq>` (global counter).
    private func publishMessage(_ message: Message, sessionID: String, namespaced: Bool) async throws {
        let conn = connection
        if namespaced, let token = await conn.writerToken {
            let n = await conn.takeWriterSequence()
            let stored = TesseraStoredMessage(seq: n, sessionID: sessionID, message: message)
            let content = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
            try await conn.publish(
                kind: TesseraConnection.messageKind,
                dTagValue: "arc/s/\(sessionID)/\(token)/\(n)",
                content: content
            )
        } else {
            let stored = TesseraStoredMessage(seq: await conn.takeSequence(), sessionID: sessionID, message: message)
            let content = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
            try await conn.publish(
                kind: TesseraConnection.messageKind,
                dTagValue: "arc/s/\(sessionID)/\(stored.seq)",
                content: content
            )
        }
    }

    /// Publish a sharee leave notice (kind 3010) for a shared session.
    /// Authored by the sharee so the relay's author-matches-deleter rule
    /// accepts it; the host reads it as "grantee severed their side".
    private func publishLeaveNotice(sessionID: String) async throws {
        let conn = connection
        guard let token = await conn.writerToken else { return }
        let notice = TesseraLeaveNotice(
            sessionID: sessionID, writer: token, at: Date()
        )
        let content = String(decoding: try JSONEncoder().encode(notice), as: UTF8.self)
        let n = await conn.takeWriterSequence()
        try await conn.publish(
            kind: TesseraConnection.leaveKind,
            dTagValue: "arc/left/\(sessionID)/\(token)/\(n)",
            content: content
        )
    }

    /// Session IDs the current identity has published a leave notice for.
    private func leaveNoticeSessionIDs(identity: String) async -> Set<String> {
        let conn = connection
        var ids: Set<String> = []
        for record in await conn.snapshot(kind: TesseraConnection.leaveKind) {
            guard record.author == identity,
                  let notice = try? JSONDecoder().decode(TesseraLeaveNotice.self, from: Data(record.content.utf8)) else {
                continue
            }
            ids.insert(notice.sessionID)
        }
        return ids
    }

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

    /// All leave notices visible to this identity (kind 3010).
    ///
    /// The host filters to notices from OTHER writers to surface "X left
    /// the session"; a sharee filters to their own for local dismissal
    /// (already applied inside `get`/`list`).
    public func leaveNotices() async -> [TesseraLeaveNotice] {
        let conn = connection
        try? await conn.ensureStarted()
        var notices: [TesseraLeaveNotice] = []
        for record in await conn.snapshot(kind: TesseraConnection.leaveKind) {
            if let notice = try? JSONDecoder().decode(TesseraLeaveNotice.self, from: Data(record.content.utf8)) {
                notices.append(notice)
            }
        }
        return notices
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
