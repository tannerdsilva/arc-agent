import Foundation
import Testing

@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// The board's contract is that the directory is the source of truth and two
    /// live instances see each other's work. Two silent-loss paths broke that:
    ///
    /// 1. `create` checked only the in-memory cache, which starts empty on a
    ///    fresh instance — so an id another instance had already written was
    ///    overwritten, losing its result, parents and children.
    /// 2. `delete` discarded the removal result (`try?`). A failed unlink left
    ///    the file in place, the caller was told nothing, and the next
    ///    hydration resurrected the task.
    @Suite("Kanban persistence integrity", .serialized)
    struct KanbanPersistenceIntegrityTests {

        private func tempBoardDirectory() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-kanban-integrity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        @Test("a second instance cannot silently overwrite a task it has not seen")
        func createRefusesForeignDuplicate() async throws {
            let dir = try tempBoardDirectory()
            let first = FileKanbanBoard(directory: dir)
            let task = KanbanTask(title: "original", body: "keep me")
            try await first.create(task)

            // A fresh instance: empty cache, same directory on disk.
            let second = FileKanbanBoard(directory: dir)
            let clobber = KanbanTask(id: task.id, title: "clobbered", body: "")

            await #expect(throws: KanbanError.self) {
                try await second.create(clobber)
            }

            let onDisk = try await first.get(id: task.id)
            #expect(onDisk?.title == "original", "the first instance's task must survive")
        }

        @Test("a delete that cannot remove the file throws instead of claiming success")
        func failedDeleteThrows() async throws {
            // Removing a directory entry needs write permission on the directory;
            // root ignores the mode bits, so skip there rather than assert a lie.
            try #require(geteuid() != 0, "mode bits do not bind root")

            let dir = try tempBoardDirectory()
            let board = FileKanbanBoard(directory: dir)
            let task = KanbanTask(title: "sticky", body: "")
            try await board.create(task)

            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }

            await #expect(throws: (any Error).self) {
                try await board.delete(id: task.id)
            }

            // Restore the directory and re-read from disk: the file survived the
            // failed delete, so a fresh instance must still see the task.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let fresh = FileKanbanBoard(directory: dir)
            let survivors = try await fresh.list(limit: 10)
            #expect(survivors.contains { $0.id == task.id },
                    "the task file survived the failed delete, so it must still list")
        }
    }
}
