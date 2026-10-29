import Foundation
import Testing

@testable import ArcAgentCore

/// D32: `FileKanbanBoard.list` returned `Array(cache.values)` and nothing
/// else. `cache` starts empty at construction, so a freshly constructed
/// board — a restarted daemon, a second process over the same directory,
/// `arc kanban list` — listed nothing until something happened to `get` a
/// task by id. Persistence was never broken (`create`/`update` write the
/// file, `get` falls back to `load`); only the primary read path lied.
///
/// These tests pin hydrate-on-read: `list` merges what is on disk into the
/// cache (an entry already in memory always wins), then filters as before.
/// A corrupt file is skipped with the same tolerance `load(id:)` has, rather
/// than failing the whole list.
@Suite("Kanban hydration")
struct KanbanHydrationTests {

    /// A board directory no other test shares.
    private func tempBoardDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-kanban-hydration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func task(
        _ title: String,
        status: TaskStatus = .todo,
        assignee: String? = nil,
        priority: Int = 0
    ) -> KanbanTask {
        KanbanTask(title: title, status: status, assignee: assignee, priority: priority)
    }

    /// The defect itself: instance A writes, instance B — over the same
    /// directory, nothing shared in memory — must list A's tasks.
    @Test("a second board over the same directory lists what the first created")
    func freshInstanceSeesTasksOnDisk() async throws {
        let dir = try tempBoardDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FileKanbanBoard(directory: dir)
        try await first.create(task("survives a restart"))
        try await first.create(task("also on disk", status: .running, assignee: "alice"))

        let second = FileKanbanBoard(directory: dir)
        let listed = try await second.list(status: nil, assignee: nil, limit: 50)

        #expect(
            listed.count == 2,
            "a fresh board listed \(listed.count) task(s), expected the 2 on disk")
        #expect(Set(listed.map(\.title)) == ["survives a restart", "also on disk"])
    }

    /// Hydration must feed the existing filter/sort/limit path, not bypass it.
    @Test("hydrated tasks still honour the status, assignee, and limit filters")
    func filtersApplyAfterHydration() async throws {
        let dir = try tempBoardDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FileKanbanBoard(directory: dir)
        try await first.create(task("one", status: .todo, assignee: "alice", priority: 1))
        try await first.create(task("two", status: .todo, assignee: "alice", priority: 2))
        try await first.create(task("three", status: .todo, assignee: "bob", priority: 3))
        try await first.create(task("four", status: .running, assignee: "bob", priority: 4))
        try await first.create(task("five", status: .review, assignee: nil, priority: 5))

        let second = FileKanbanBoard(directory: dir)

        let all = try await second.list(status: nil, assignee: nil, limit: 50)
        #expect(all.count == 5, "hydrated board listed \(all.count) task(s), expected 5")

        let todos = try await second.list(status: .todo, assignee: nil, limit: 50)
        #expect(Set(todos.map(\.title)) == ["one", "two", "three"])

        let alices = try await second.list(status: nil, assignee: "alice", limit: 50)
        #expect(Set(alices.map(\.title)) == ["one", "two"])

        let alicesTodos = try await second.list(status: .todo, assignee: "alice", limit: 50)
        #expect(Set(alicesTodos.map(\.title)) == ["one", "two"])

        let limited = try await second.list(status: nil, assignee: nil, limit: 2)
        #expect(
            limited.map(\.title) == ["five", "four"],
            "limit picked \(limited.map(\.title)) — expected the two highest priorities")
    }

    /// The rule the brief states: an in-memory entry wins. Hydration may only
    /// add tasks this instance has not seen, never overwrite what it holds.
    @Test("an in-memory entry wins over the file it already persisted")
    func cacheWinsOverDisk() async throws {
        let dir = try tempBoardDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let board = FileKanbanBoard(directory: dir)
        let created = task("as created")
        try await board.create(created)

        // Another writer changes the file behind this board's back.
        var changed = created
        changed.title = "changed elsewhere"
        try JSONEncoder().encode(changed).write(to: dir.appendingPathComponent("\(created.id).json"))

        let listed = try await board.list(status: nil, assignee: nil, limit: 50)
        #expect(
            listed.map(\.title) == ["as created"],
            "hydration overwrote an in-memory entry: \(listed.map(\.title))")

        // A board that has never seen the task reads the file as it is.
        let second = FileKanbanBoard(directory: dir)
        let fresh = try await second.list(status: nil, assignee: nil, limit: 50)
        #expect(fresh.map(\.title) == ["changed elsewhere"])
    }

    /// A corrupt task file must not fail the whole list — the tolerance
    /// `load(id:)` already has, extended to the directory walk.
    @Test("a malformed task file is skipped, not thrown")
    func malformedFilesDoNotFailTheList() async throws {
        let dir = try tempBoardDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FileKanbanBoard(directory: dir)
        try await first.create(task("good one"))
        try await first.create(task("good two"))

        try Data("{ not a task".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try Data().write(to: dir.appendingPathComponent("empty.json"))
        try Data(#"{"unexpected": true}"#.utf8)
            .write(to: dir.appendingPathComponent("shape.json"))

        let second = FileKanbanBoard(directory: dir)
        let listed = try await second.list(status: nil, assignee: nil, limit: 50)
        #expect(
            listed.count == 2,
            "a corrupt file changed the result: \(listed.map(\.title))")
        #expect(Set(listed.map(\.title)) == ["good one", "good two"])
    }
}
