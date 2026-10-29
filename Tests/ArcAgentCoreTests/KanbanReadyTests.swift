import Foundation
import Testing

@testable import ArcAgentCore

/// D34: `FileKanbanBoard.recomputeReady` had two defects in one function.
///
/// 1. It iterated `cache.values` and never hydrated, so on a freshly
///    constructed board it promoted nothing. `KanbanDispatcher` calls
///    `recomputeReady()` before `list()`, so a restarted daemon's first tick
///    did nothing useful.
/// 2. It resolved a dependency with `cache[parentID]?.status == .done`, which
///    reads an **uncached** parent as *not done* — so a child whose parent was
///    completed by a different instance never became ready, even once the
///    board could see the directory.
///
/// These tests pin hydrate-then-resolve: `recomputeReady` merges the directory
/// into the cache first, and resolves each parent through the cache and then
/// the file. `allSatisfy` semantics stay: no parents means promote, an unknown
/// parent still blocks.
@Suite("Kanban ready")
struct KanbanReadyTests {

    /// A board directory no other test shares.
    private func tempBoardDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-kanban-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func task(
        _ title: String,
        status: TaskStatus = .todo,
        parents: [String] = []
    ) -> KanbanTask {
        KanbanTask(title: title, status: status, parents: parents)
    }

    /// The defect itself: instance A completes a parent and leaves a child
    /// that depends on it. Instance B — same directory, empty cache — must
    /// promote the child when it recomputes readiness.
    @Test("a second board promotes a child whose parent another instance completed")
    func freshInstanceResolvesParentsOnDisk() async throws {
        let dir = try tempBoardDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FileKanbanBoard(directory: dir)
        let parent = task("finished parent", status: .done)
        try await first.create(parent)
        let child = task("waiting child", status: .todo, parents: [parent.id])
        try await first.create(child)

        let second = FileKanbanBoard(directory: dir)
        try await second.recomputeReady()

        let promoted = try await second.get(id: child.id)
        #expect(
            promoted?.status == .ready,
            "a fresh board left the child at \(promoted?.status.rawValue ?? "nil"), expected ready")
    }

    /// The common case the fix must not regress: with no parents the
    /// `allSatisfy` check is vacuously true, so a plain `todo` task promotes.
    @Test("a task with no parents still promotes to ready")
    func taskWithoutParentsPromotes() async throws {
        let dir = try tempBoardDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FileKanbanBoard(directory: dir)
        let standalone = task("nobody is waiting on me")
        try await first.create(standalone)

        let second = FileKanbanBoard(directory: dir)
        try await second.recomputeReady()

        let promoted = try await second.get(id: standalone.id)
        #expect(
            promoted?.status == .ready,
            "a parentless task stayed at \(promoted?.status.rawValue ?? "nil"), expected ready")
    }

    /// An unfinished parent still blocks — the whole point of the dependency.
    @Test("a task whose parent is still todo does not promote")
    func unfinishedParentBlocks() async throws {
        let dir = try tempBoardDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FileKanbanBoard(directory: dir)
        let parent = task("still queued", status: .todo)
        try await first.create(parent)
        let child = task("blocked child", status: .todo, parents: [parent.id])
        try await first.create(child)

        let second = FileKanbanBoard(directory: dir)
        try await second.recomputeReady()

        let stillWaiting = try await second.get(id: child.id)
        #expect(
            stillWaiting?.status == .todo,
            "a child of an unfinished parent was promoted to \(stillWaiting?.status.rawValue ?? "nil")")
    }

    /// One tick over a mixed board: exactly the eligible tasks promote, and
    /// each promotion is persisted, so a third instance reads it back.
    @Test("one recompute promotes exactly the eligible tasks and persists them")
    func recomputeIsSelectiveAndPersistent() async throws {
        let dir = try tempBoardDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FileKanbanBoard(directory: dir)
        let done = task("done parent", status: .done)
        let todo = task("todo parent", status: .todo)
        try await first.create(done)
        try await first.create(todo)

        let readyChild = task("parent is done", parents: [done.id])
        let blockedChild = task("parent is todo", parents: [todo.id])
        let standalone = task("no parents at all")
        try await first.create(readyChild)
        try await first.create(blockedChild)
        try await first.create(standalone)

        let second = FileKanbanBoard(directory: dir)
        try await second.recomputeReady()

        let promoted = try await second.list(status: .ready, assignee: nil, limit: 50)
        #expect(
            Set(promoted.map(\.title)) == ["parent is done", "todo parent", "no parents at all"],
            "promoted \(promoted.map(\.title)) — expected only the eligible tasks")

        // Persisted: a third board sees the transitions without recomputing.
        let third = FileKanbanBoard(directory: dir)
        let onDisk = try await third.get(id: readyChild.id)
        #expect(onDisk?.status == .ready, "the promotion was not saved to disk")

        // An unknown parent (no file, no cache entry) still blocks, as before.
        let orphan = task("parent is gone", parents: ["missing-\(UUID().uuidString)"])
        try await second.create(orphan)
        try await second.recomputeReady()
        let orphanAfter = try await second.get(id: orphan.id)
        #expect(
            orphanAfter?.status == .todo,
            "a child of a missing parent was promoted to \(orphanAfter?.status.rawValue ?? "nil")")
    }
}
