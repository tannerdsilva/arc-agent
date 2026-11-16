import Foundation

/// A `KanbanAgentStore` backed by local JSON files — the LOCAL offline
/// fallback (spec 03 §4), shaped like `FileCronStore`.
///
/// Layout under `root` (default `~/.arc/kanban-agent/`):
///
/// ```
/// boards/<id>.json                    board documents
/// boards/<id>/cards/<cardID>.json     per-card records
/// boards/<id>/events.jsonl            append-only event log
/// ```
///
/// Writes are atomic (write-to-temp + rename); reads decode from disk each
/// time — the file counts here are small and this store exists to keep arc
/// fully functional with no relay.
public actor FileKanbanAgentStore: KanbanAgentStore {

    private let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let arcHome = ProcessInfo.processInfo.environment["ARC_HOME"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: NSString(string: "~/.arc").expandingTildeInPath, isDirectory: true)
            self.root = arcHome.appendingPathComponent("kanban-agent", isDirectory: true)
        }
    }

    // MARK: - Paths

    private func boardURL(_ id: String) -> URL {
        root.appendingPathComponent("boards/\(id).json")
    }
    private func cardsDir(_ boardID: String) -> URL {
        root.appendingPathComponent("boards/\(boardID)/cards", isDirectory: true)
    }
    private func cardURL(_ boardID: String, _ cardID: String) -> URL {
        cardsDir(boardID).appendingPathComponent("\(cardID).json")
    }
    private func eventsURL(_ boardID: String) -> URL {
        root.appendingPathComponent("boards/\(boardID)/events.jsonl")
    }

    // MARK: - Helpers

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func readBoard(id: String) throws -> KanbanAgent.BoardDocument? {
        let url = boardURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(KanbanAgent.BoardDocument.self, from: Data(contentsOf: url))
    }

    // MARK: - Boards

    public func saveBoard(_ board: KanbanAgent.BoardDocument) async throws {
        if let existing = try readBoard(id: board.id) {
            guard board.revision == existing.revision + 1 else {
                throw KanbanAgentStoreError.revisionConflict(expected: existing.revision + 1, got: board.revision)
            }
        } else {
            guard board.revision == 0 else {
                throw KanbanAgentStoreError.revisionConflict(expected: 0, got: board.revision)
            }
        }
        try atomicWrite(try Self.encoder.encode(board), to: boardURL(board.id))
    }

    public func getBoard(id: String) async throws -> KanbanAgent.BoardDocument? {
        try readBoard(id: id)
    }

    public func listBoards() async throws -> [KanbanAgent.BoardDocument] {
        let dir = root.appendingPathComponent("boards", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(KanbanAgent.BoardDocument.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }

    public func deleteBoard(id: String) async throws {
        guard try readBoard(id: id) != nil else {
            throw KanbanAgentStoreError.boardNotFound(id)
        }
        try? FileManager.default.removeItem(at: boardURL(id))
        try? FileManager.default.removeItem(at: cardsDir(id))
        try? FileManager.default.removeItem(at: eventsURL(id))
    }

    // MARK: - Cards

    public func saveCard(_ card: KanbanAgent.Card, boardID: String) async throws {
        guard try readBoard(id: boardID) != nil else {
            throw KanbanAgentStoreError.boardNotFound(boardID)
        }
        // Card records are replace-on-write keyed by id; the board document's
        // revision is the concurrency boundary, so cards don't carry their own
        // revision — last write within the engine's actor wins (spec 03 §2).
        try atomicWrite(try Self.encoder.encode(card), to: cardURL(boardID, card.id))
    }

    public func getCard(id: String, boardID: String) async throws -> KanbanAgent.Card? {
        let url = cardURL(boardID, id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(KanbanAgent.Card.self, from: Data(contentsOf: url))
    }

    public func cards(boardID: String) async throws -> [KanbanAgent.Card] {
        let dir = cardsDir(boardID)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(KanbanAgent.Card.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }

    public func deleteCard(id: String, boardID: String) async throws {
        guard try await getCard(id: id, boardID: boardID) != nil else {
            throw KanbanAgentStoreError.cardNotFound(boardID: boardID, cardID: id)
        }
        try? FileManager.default.removeItem(at: cardURL(boardID, id))
    }

    // MARK: - Events

    public func appendEvent(_ event: KanbanAgent.BoardEvent, boardID: String) async throws {
        guard try readBoard(id: boardID) != nil else {
            throw KanbanAgentStoreError.boardNotFound(boardID)
        }
        let lastSeq = try readEvents(boardID: boardID).last?.seq ?? 0
        guard event.seq == lastSeq + 1 else {
            throw KanbanAgentStoreError.eventSequenceConflict(expected: lastSeq + 1, got: event.seq)
        }
        let line = String(decoding: try Self.encoder.encode(event), as: UTF8.self) + "\n"
        let url = eventsURL(boardID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    public func events(boardID: String, after seq: Int, limit: Int) async throws -> [KanbanAgent.BoardEvent] {
        guard try readBoard(id: boardID) != nil else {
            throw KanbanAgentStoreError.boardNotFound(boardID)
        }
        return Array(try readEvents(boardID: boardID).filter { $0.seq > seq }.prefix(limit))
    }

    private func readEvents(boardID: String) throws -> [KanbanAgent.BoardEvent] {
        let url = eventsURL(boardID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? Self.decoder.decode(KanbanAgent.BoardEvent.self, from: Data($0.utf8)) }
    }
}
