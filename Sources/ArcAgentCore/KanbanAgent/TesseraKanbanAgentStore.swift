import Foundation

/// A `KanbanAgentStore` backed by a Tessera server — the primary store
/// (spec 03 §3), following the `TesseraCronStore` pattern: cache-first
/// snapshot decode, echo-awaiting writes, tombstone deletion.
///
/// Layout (all under the global `arc/` dTag prefix):
///
/// ```
/// kind 3011  arc/kb/board/<boardID>/<seq>                 board documents
/// kind 3012  arc/kb/board/<boardID>/card/<cardID>/<seq>   per-card records
/// kind 3013  arc/kb/board/<boardID>/evt/<seq>             append-only event log
/// ```
public actor TesseraKanbanAgentStore: KanbanAgentStore {

    public static let boardKind: UInt32 = 3_011
    public static let cardKind: UInt32 = 3_012
    public static let eventKind: UInt32 = 3_013

    private var connection: TesseraConnection { TesseraConnection.shared }

    private var boards: [String: KanbanAgent.BoardDocument] = [:]
    private var cards: [String: [String: KanbanAgent.Card]] = [:]   // boardID → cardID → card
    private var eventHeadsByBoard: [String: Int] = [:]             // boardID → latest event seq
    private var loaded = false
    private var lastSync = Date.distantPast

    public init() {}

    // MARK: - dTags (exposed for unit tests)

    public static func boardDTag(boardID: String, seq: Int) -> String {
        "arc/kb/board/\(boardID)/\(seq)"
    }
    public static func cardDTag(boardID: String, cardID: String, seq: Int) -> String {
        "arc/kb/board/\(boardID)/card/\(cardID)/\(seq)"
    }
    public static func eventDTag(boardID: String, seq: Int) -> String {
        "arc/kb/board/\(boardID)/evt/\(seq)"
    }

    // MARK: - Snapshot decoding (pure helpers, unit-testable)

    /// Collapse board snapshots into the newest document per board id.
    /// Unwrap the `TesseraKanbanRecord` envelope persisted as event content —
    /// `publishRecord` writes `{"seq":N,"payload":<base64>}`, so the payload
    /// must be unwrapped before decoding (same rule as `TesseraCronRecord`).
    static func payload(from record: TesseraRecord) -> Data? {
        if let envelope = try? JSONDecoder().decode(TesseraKanbanRecord.self, from: Data(record.content.utf8)) {
            return envelope.payload
        }
        // Legacy/fallback: content stored as the bare record JSON.
        return Data(record.content.utf8)
    }

    public static func latestBoards(from records: [TesseraRecord]) -> [String: KanbanAgent.BoardDocument] {
        var latest: [String: (seq: Int, doc: KanbanAgent.BoardDocument)] = [:]
        for record in records {
            guard let dTag = record.dTag,
                  dTag.hasPrefix("arc/kb/board/"),
                  !dTag.contains("/card/"), !dTag.contains("/evt/"),
                  let seq = TesseraConnection.sequenceNumber(fromTagKey: dTag),
                  let payload = Self.payload(from: record),
                  let doc = try? JSONDecoder().decode(KanbanAgent.BoardDocument.self, from: payload)
            else { continue }
            if let existing = latest[doc.id], existing.seq >= seq { continue }
            latest[doc.id] = (seq, doc)
        }
        return latest.mapValues(\.doc)
    }

    /// Collapse card snapshots into the newest card per (board, card) pair.
    /// Identity is the dTag *prefix* (everything before the global seq) —
    /// each save republishes the same prefix with a new seq, and the highest
    /// seq per prefix wins.
    public static func latestCards(from records: [TesseraRecord]) -> [String: [String: KanbanAgent.Card]] {
        var latest: [String: (seq: Int, card: KanbanAgent.Card)] = [:]
        for record in records {
            guard let dTag = record.dTag,
                  dTag.hasPrefix("arc/kb/board/"), dTag.contains("/card/"),
                  let seq = TesseraConnection.sequenceNumber(fromTagKey: dTag),
                  let payload = Self.payload(from: record),
                  let card = try? JSONDecoder().decode(KanbanAgent.Card.self, from: payload)
            else { continue }
            // "arc/kb/board/<b>/card/<c>/<seq>" → "arc/kb/board/<b>/card/<c>"
            let prefix = String(dTag.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/"))
            if let existing = latest[prefix], existing.seq >= seq { continue }
            latest[prefix] = (seq, card)
        }
        var result: [String: [String: KanbanAgent.Card]] = [:]
        for (dTag, entry) in latest {
            guard let boardID = boardID(fromCardDTag: dTag) else { continue }
            result[boardID, default: [:]][entry.card.id] = entry.card
        }
        return result
    }

    /// Highest event seq per board from a snapshot.
    public static func eventHeads(from records: [TesseraRecord]) -> [String: Int] {
        var heads: [String: Int] = [:]
        for record in records {
            guard let dTag = record.dTag,
                  dTag.hasPrefix("arc/kb/board/"), dTag.contains("/evt/"),
                  let seq = TesseraConnection.sequenceNumber(fromTagKey: dTag)
            else { continue }
            let id = String(dTag.dropFirst("arc/kb/board/".count).prefix(while: { $0 != "/" }))
            if seq > (heads[id] ?? 0) { heads[id] = seq }
        }
        return heads
    }

    /// Extract the board id from a card dTag: `arc/kb/board/<id>/card/<cid>/<seq>`.
    public static func boardID(fromCardDTag dTag: String) -> String? {
        let rest = dTag.dropFirst("arc/kb/board/".count)
        guard let slash = rest.firstIndex(of: "/"), rest[slash...].hasPrefix("/card/") else { return nil }
        return String(rest[..<slash])
    }

    /// `arc/kb/board/<id>/evt/<seq>` → seq. The dTag seq is the event's
    /// logical identity; the payload's `seq` field must match it.
    public static func sequence(fromEventDTag dTag: String) -> Int? {
        guard dTag.hasPrefix("arc/kb/board/"), dTag.contains("/evt/") else { return nil }
        return Int(dTag.split(separator: "/").last ?? "")
    }

    // MARK: - Private

    private func ensureLoaded() async throws {
        let conn = connection
        if loaded, Date().timeIntervalSince(lastSync) < 5 { return }
        try await conn.ensureStarted()
        boards = Self.latestBoards(from: await conn.snapshot(kind: Self.boardKind))
        cards = Self.latestCards(from: await conn.snapshot(kind: Self.cardKind))
        eventHeadsByBoard = Self.eventHeads(from: await conn.snapshot(kind: Self.eventKind))
        lastSync = Date()
        loaded = true
    }

    /// Publish one record and await the relay echo (correctness-critical,
    /// low-frequency writes — same rule as cron). The dTag is
    /// `<dTagPrefix>/<globalSeq>`; the global seq is also embedded in the
    /// record envelope, mirroring `TesseraCronRecord`.
    private func publishRecord(kind: UInt32, dTagPrefix: String, payload: Data) async throws {
        let conn = connection
        try await conn.ensureStarted()
        let seq = await conn.takeSequence()
        let record = TesseraKanbanRecord(seq: seq, payload: payload)
        let content = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        do {
            _ = try await conn.publishAwaitingEcho(kind: kind, dTagValue: "\(dTagPrefix)/\(seq)", content: content)
        } catch TesseraStoreError.echoTimeout {
            throw KanbanAgentStoreError.echoTimeout("dTag \(dTagPrefix)/… not persisted")
        }
    }

    // MARK: - KanbanAgentStore: boards

    public func saveBoard(_ board: KanbanAgent.BoardDocument) async throws {
        try await ensureLoaded()
        if let existing = boards[board.id] {
            guard board.revision == existing.revision + 1 else {
                throw KanbanAgentStoreError.revisionConflict(expected: existing.revision + 1, got: board.revision)
            }
        } else {
            guard board.revision == 0 else {
                throw KanbanAgentStoreError.revisionConflict(expected: 0, got: board.revision)
            }
        }
        let seq = await connection.takeSequence()
        try await publishRecord(
            kind: Self.boardKind,
            dTagPrefix: "arc/kb/board/\(board.id)",
            payload: try JSONEncoder().encode(board))
        boards[board.id] = board
    }

    public func getBoard(id: String) async throws -> KanbanAgent.BoardDocument? {
        try await ensureLoaded()
        return boards[id]
    }

    public func listBoards() async throws -> [KanbanAgent.BoardDocument] {
        try await ensureLoaded()
        return boards.values.sorted { $0.id < $1.id }
    }

    public func deleteBoard(id: String) async throws {
        try await ensureLoaded()
        guard boards[id] != nil else { throw KanbanAgentStoreError.boardNotFound(id) }
        let conn = connection
        try await conn.deleteAll(dTagPrefix: "arc/kb/board/\(id)/", kind: Self.boardKind)
        try await conn.deleteAll(dTagPrefix: "arc/kb/board/\(id)/card/", kind: Self.cardKind)
        try await conn.deleteAll(dTagPrefix: "arc/kb/board/\(id)/evt/", kind: Self.eventKind)
        boards[id] = nil
        cards[id] = nil
        eventHeadsByBoard[id] = nil
    }

    // MARK: - KanbanAgentStore: cards

    public func saveCard(_ card: KanbanAgent.Card, boardID: String) async throws {
        try await ensureLoaded()
        guard boards[boardID] != nil else { throw KanbanAgentStoreError.boardNotFound(boardID) }
        try await publishRecord(
            kind: Self.cardKind,
            dTagPrefix: "arc/kb/board/\(boardID)/card/\(card.id)",
            payload: try JSONEncoder().encode(card))
        cards[boardID, default: [:]][card.id] = card
    }

    public func getCard(id: String, boardID: String) async throws -> KanbanAgent.Card? {
        try await ensureLoaded()
        return cards[boardID]?[id]
    }

    public func cards(boardID: String) async throws -> [KanbanAgent.Card] {
        try await ensureLoaded()
        return Array(cards[boardID]?.values ?? [:].values).sorted { $0.id < $1.id }
    }

    public func deleteCard(id: String, boardID: String) async throws {
        try await ensureLoaded()
        guard cards[boardID]?[id] != nil else {
            throw KanbanAgentStoreError.cardNotFound(boardID: boardID, cardID: id)
        }
        let conn = connection
        try await conn.deleteAll(dTagPrefix: "arc/kb/board/\(boardID)/card/\(id)/", kind: Self.cardKind)
        cards[boardID]?[id] = nil
    }

    // MARK: - KanbanAgentStore: events

    public func appendEvent(_ event: KanbanAgent.BoardEvent, boardID: String) async throws {
        try await ensureLoaded()
        guard boards[boardID] != nil else { throw KanbanAgentStoreError.boardNotFound(boardID) }
        let expected = (eventHeadsByBoard[boardID] ?? 0) + 1
        guard event.seq == expected else {
            throw KanbanAgentStoreError.eventSequenceConflict(expected: expected, got: event.seq)
        }
        try await publishRecord(
            kind: Self.eventKind,
            dTagPrefix: "arc/kb/board/\(boardID)/evt",
            payload: try JSONEncoder().encode(event))
        eventHeadsByBoard[boardID] = event.seq
    }

    public func events(boardID: String, after seq: Int, limit: Int) async throws -> [KanbanAgent.BoardEvent] {
        try await ensureLoaded()
        let records = await connection.snapshot(kind: Self.eventKind)
        var events: [(seq: Int, event: KanbanAgent.BoardEvent)] = []
        for record in records {
            guard let dTag = record.dTag, dTag.hasPrefix("arc/kb/board/\(boardID)/evt/"),
                  let payload = Self.payload(from: record),
                  let event = try? JSONDecoder().decode(KanbanAgent.BoardEvent.self, from: payload)
            else { continue }
            events.append((Self.sequence(fromEventDTag: dTag) ?? 0, event))
        }
        var seen = Set<Int>()
        let deduped = events.sorted { $0.seq < $1.seq }.filter { seen.insert($0.seq).inserted }
        return Array(deduped.filter { $0.seq > seq }.prefix(limit).map(\.event))
    }
}

/// The envelope persisted as event content: a global sequence plus the JSON
/// payload of the record it wraps (mirrors `TesseraCronRecord`).
public struct TesseraKanbanRecord: Codable, Sendable {
    public var seq: Int
    public var payload: Data

    public init(seq: Int, payload: Data) {
        self.seq = seq
        self.payload = payload
    }
}
