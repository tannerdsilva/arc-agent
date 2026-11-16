import Foundation

/// Storage for kanban-agent boards (docs/kanban-specs/03-storage-tessera.md).
///
/// Cards are their own records (answer 1); the board document holds graph,
/// lanes, roots, and settings. Events are append-only with a per-board
/// monotonic sequence. All writers flow through the daemon's engine actor
/// (spec 04 §1), so `save*` methods enforce revision discipline: a write
/// whose `revision` is not `latest + 1` (initial save: `0`) throws
/// `.revisionConflict` rather than silently clobbering.
public protocol KanbanAgentStore: Sendable {
    // Boards
    func saveBoard(_ board: KanbanAgent.BoardDocument) async throws
    func getBoard(id: String) async throws -> KanbanAgent.BoardDocument?
    func listBoards() async throws -> [KanbanAgent.BoardDocument]
    func deleteBoard(id: String) async throws

    // Cards — per-card records
    func saveCard(_ card: KanbanAgent.Card, boardID: String) async throws
    func getCard(id: String, boardID: String) async throws -> KanbanAgent.Card?
    func cards(boardID: String) async throws -> [KanbanAgent.Card]
    func deleteCard(id: String, boardID: String) async throws

    // Events — append-only audit log
    func appendEvent(_ event: KanbanAgent.BoardEvent, boardID: String) async throws
    func events(boardID: String, after seq: Int, limit: Int) async throws -> [KanbanAgent.BoardEvent]
}

/// Storage failures (spec 03 §5).
public enum KanbanAgentStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A `save` arrived with a revision that is not `latest + 1`.
    case revisionConflict(expected: Int, got: Int)
    /// A `BoardEvent.seq` that is not `latest + 1`.
    case eventSequenceConflict(expected: Int, got: Int)
    /// The board does not exist.
    case boardNotFound(String)
    /// The card does not exist.
    case cardNotFound(boardID: String, cardID: String)
    /// The relay echo never arrived — the write must be treated as absent.
    case echoTimeout(String)

    public var description: String {
        switch self {
        case .revisionConflict(let expected, let got):
            return "revision conflict: expected \(expected), got \(got)"
        case .eventSequenceConflict(let expected, let got):
            return "event sequence conflict: expected \(expected), got \(got)"
        case .boardNotFound(let id):
            return "board '\(id)' not found"
        case .cardNotFound(let board, let card):
            return "card '\(card)' not found on board '\(board)'"
        case .echoTimeout(let what):
            return "tessera echo timeout: \(what)"
        }
    }
}
