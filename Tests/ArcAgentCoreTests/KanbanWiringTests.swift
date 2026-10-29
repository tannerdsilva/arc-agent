import Foundation
import Testing

@testable import ArcAgentCore

/// D22: the five `kanban_*` tools read a `ToolDependency<any KanbanBoard>` slot
/// (`KanbanTools.swift:14`, `:30`, and the same in `list`/`show`/`complete`/
/// `block`) that **no production call site filled**. The board was real and
/// constructed twice in the process — the daemon's dispatcher and the CLI's
/// `arc kanban list` — while every agent surface built its registry through
/// `MutableToolRegistry.make`, which had no `kanban:` parameter and could not
/// forward one. The slot stayed empty, so every call answered
/// "Error: Kanban board not available."
///
/// These tests pin the seam that was missing: one registry built **with** a
/// board must act on that board for every call, and one built **without** must
/// keep the honest refusal rather than crash on an empty slot.
@Suite("Kanban wiring")
struct KanbanWiringTests {

    /// A board directory no other test shares.
    private func tempBoardDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-kanban-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The refusal every `kanban_*` tool answers with when its surface carries
    /// no board. Spelled out here rather than restated loosely: the tools'
    /// strings are the contract, and a nil-board surface must not become a
    /// crash, an empty list, or a silently fabricated task.
    private static let refusal = "Error: Kanban board not available."

    private func call(
        _ registry: MutableToolRegistry, _ name: String, _ args: sending [String: Any] = [:]
    ) async throws -> String {
        let tool = try #require(registry.lookup(name: name)).tool
        return try await tool.handler(args)
    }

    /// The round trip through one registry: a task created by `kanban_create`
    /// is visible to `kanban_list` — and to the board instance the caller
    /// handed over, not to a board the builder invented.
    @Test("a board handed to make() is the board every kanban tool acts on")
    func boardReachesTheTools() async throws {
        let dir = try tempBoardDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = FileKanbanBoard(directory: dir)

        let registry = try await MutableToolRegistry.make(
            context: ArcAgentCore.testContext(),
            profiles: TesseraProfileStore.shared,
            memory: FileMemoryProvider(),
            sessions: FileSessionStore(),
            kanban: board
        )

        let created = try await call(registry, "kanban_create", ["title": "wire the board"])
        #expect(created.hasPrefix("Task created:"), "kanban_create did not create: \(created)")

        let listed = try await call(registry, "kanban_list")
        #expect(
            listed.contains("wire the board"),
            "the task created through this registry is not on the board its kanban_list reads: \(listed)")

        // And it is *this* board that holds it — the one the caller owns, which
        // the daemon also hands to its dispatcher and the CLI administers.
        let onBoard = try await board.list(status: nil, assignee: nil, limit: 10)
        #expect(onBoard.count == 1, "the handed-over board holds \(onBoard.count) task(s), expected 1")
        #expect(onBoard.first?.title == "wire the board")

        // `kanban_show` resolves through the same slot.
        let id = try #require(onBoard.first?.id)
        let shown = try await call(registry, "kanban_show", ["id": id])
        #expect(shown.contains("wire the board"), "kanban_show did not read the board: \(shown)")
    }

    /// The other half: a surface built with no board keeps today's behaviour —
    /// the tools stay in the compiled list and answer that none is available.
    /// They must not construct one (the builder binds the one it is given).
    @Test("a surface built without a board refuses honestly")
    func nilBoardRefusesHonestly() async throws {
        let registry = try await MutableToolRegistry.make(
            context: ArcAgentCore.testContext(),
            profiles: TesseraProfileStore.shared,
            memory: FileMemoryProvider(),
            sessions: FileSessionStore()
        )

        // The tools are still registered: the surface advertises them, it just
        // has no board behind them.
        #expect(registry.lookup(name: "kanban_create") != nil)
        #expect(registry.lookup(name: "kanban_list") != nil)

        let created = try await call(registry, "kanban_create", ["title": "nowhere to put this"])
        #expect(created == Self.refusal, "nil-board kanban_create answered: \(created)")

        let listed = try await call(registry, "kanban_list")
        #expect(listed == Self.refusal, "nil-board kanban_list answered: \(listed)")
    }
}
