import Foundation

/// A session's standing goal persisted as a Tessera event (kind 3006),
/// mirroring the session-store record shape: JSON payload in the event
/// content, `d` tag `arc/goals/<sessionID>/<seq>`.
public struct TesseraGoalRecord: Codable, Sendable, Equatable {
    /// The global sequence number of this event.
    public var seq: Int
    /// The session this goal belongs to.
    public var sessionID: String
    /// The goal state snapshot.
    public var state: GoalState

    public init(seq: Int, sessionID: String, state: GoalState) {
        self.seq = seq
        self.sessionID = sessionID
        self.state = state
    }
}

/// A ``GoalStoring`` backed by a Tessera server.
///
/// Goals are stored as signed NOSTR events through the shared
/// ``TesseraConnection``:
///
/// - Goals: kind 3006, `d` tag `arc/goals/<sessionID>/<seq>`
///
/// Write-through: every mutation publishes a new event (newest per session
/// wins on load) and updates the in-memory cache; ``save()`` is a no-op.
public actor TesseraGoalStore: GoalStoring {

    public static let kind: UInt32 = 3_006

    private var connection: TesseraConnection { TesseraConnection.shared }

    private var cache: [String: GoalState] = [:]
    private var loaded = false

    public init() {}

    // MARK: - Helpers (exposed for unit tests)

    /// `d` tag value for a goal event.
    public static func dTag(for sessionID: String, seq: Int) -> String {
        "arc/goals/\(sessionID)/\(seq)"
    }

    /// Decode a snapshot into the newest goal per session (highest seq wins).
    public static func latestBySession(from records: [TesseraRecord]) -> [String: GoalState] {
        var latest: [String: (seq: Int, state: GoalState)] = [:]
        for record in records {
            guard let dTag = record.dTag,
                  dTag.hasPrefix("arc/goals/"),
                  let seq = TesseraConnection.sequenceNumber(fromTagKey: dTag),
                  let decoded = try? JSONDecoder().decode(TesseraGoalRecord.self, from: Data(record.content.utf8))
            else { continue }
            let id = decoded.sessionID
            if let existing = latest[id], existing.seq >= seq { continue }
            latest[id] = (seq, decoded.state)
        }
        return latest.mapValues(\.state)
    }

    // MARK: - GoalStoring

    public func set(sessionID: String, state: GoalState) async throws {
        var s = state
        s.createdAt = Date()
        s.updatedAt = Date()
        try await publish(sessionID: sessionID, state: s)
        cache[sessionID] = s
    }

    public func get(sessionID: String) async throws -> GoalState? {
        try await ensureLoaded()
        return cache[sessionID]
    }

    public func update(sessionID: String, _ mutate: @Sendable (inout GoalState) -> Void) async throws {
        try await ensureLoaded()
        guard var g = cache[sessionID] else { return }
        mutate(&g)
        g.updatedAt = Date()
        try await publish(sessionID: sessionID, state: g)
        cache[sessionID] = g
    }

    public func clear(sessionID: String) async throws {
        try await ensureLoaded()
        let conn = connection
        try await conn.ensureStarted()
        try await conn.deleteAll(dTagPrefix: "arc/goals/\(sessionID)/", kind: Self.kind)
        cache[sessionID] = nil
    }

    public func all() async throws -> [String: GoalState] {
        try await ensureLoaded()
        return cache
    }

    public func save() async throws {
        // Write-through: nothing buffered. Kept for protocol parity with
        // the file backend.
    }

    // MARK: - Private

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        let conn = connection
        try await conn.ensureStarted()
        cache = Self.latestBySession(from: await conn.snapshot(kind: Self.kind))
        loaded = true
    }

    private func publish(sessionID: String, state: GoalState) async throws {
        let conn = connection
        try await conn.ensureStarted()
        let seq = await conn.takeSequence()
        let content = String(
            decoding: try JSONEncoder().encode(TesseraGoalRecord(seq: seq, sessionID: sessionID, state: state)),
            as: UTF8.self)
        try await conn.publish(kind: Self.kind, dTagValue: Self.dTag(for: sessionID, seq: seq), content: content)
    }
}
