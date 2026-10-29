import Foundation
import Testing

@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// Tool arguments are untrusted input: they come from a model, a JSON
    /// payload, or a human typing a flag. A count argument that reaches a
    /// collection slice has to be clamped or rejected first — `prefix(_:)` and
    /// `Range(lower..<upper)` both **trap** on a negative length, which takes
    /// the whole process down mid-turn instead of answering the tool call.
    ///
    /// The contract these tests pin, in the order the value travels:
    /// 1. The **tool boundary** rejects a nonsensical count with an `Error:`
    ///    string — the model can read it and correct itself next turn.
    /// 2. The **slicing site** clamps anyway (`max(0, …)`), so no other caller
    ///    (CLI flag, internal loop) can reach a trapping slice.
    @Suite("Tool argument bounds", .serialized)
    struct ToolArgumentBoundsTests {

        /// A three-line file in a directory no other test shares.
        private func tempFile() throws -> String {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-arg-bounds-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("sample.txt")
            try "alpha\nbeta\ngamma\n".write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }

        private func tempBoard() throws -> FileKanbanBoard {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-arg-bounds-board-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return FileKanbanBoard(directory: dir)
        }

        // MARK: - read_file

        @Test("read_file rejects a non-positive limit instead of trapping")
        func readFileNegativeLimit() async throws {
            let path = try tempFile()
            let output = try await ReadFileTool.entry.handler(["path": path, "limit": -1])
            #expect(output.hasPrefix("Error:"), "expected a readable error, got: \(output)")
            #expect(output.contains("limit"))
            // The process is still alive and the tool still works.
            let ok = try await ReadFileTool.entry.handler(["path": path, "limit": 2])
            #expect(ok.contains("alpha"))
            #expect(ok.contains("beta"))
        }

        @Test("read_file rejects a negative offset instead of trapping")
        func readFileNegativeOffset() async throws {
            let path = try tempFile()
            let output = try await ReadFileTool.entry.handler(["path": path, "offset": -4])
            #expect(output.hasPrefix("Error:"), "expected a readable error, got: \(output)")
            #expect(output.contains("offset"))
        }

        // MARK: - kanban_list

        @Test("kanban_list rejects a non-positive limit instead of trapping")
        func kanbanNegativeLimit() async throws {
            let board = try tempBoard()
            try await board.create(KanbanTask(title: "one", body: ""))
            let tool = KanbanTools.list(board: ToolDependency<any KanbanBoard>(board))
            let output = try await tool.handler(["limit": -1])
            #expect(output.hasPrefix("Error:"), "expected a readable error, got: \(output)")
            #expect(output.contains("limit"))
        }

        @Test("the board clamps a negative limit, so every caller is safe")
        func boardClampsLimit() async throws {
            let board = try tempBoard()
            try await board.create(KanbanTask(title: "one", body: ""))
            try await board.create(KanbanTask(title: "two", body: ""))
            let tasks = try await board.list(limit: -1)
            #expect(tasks.isEmpty, "a negative limit means no rows, never a trap")
        }

        // MARK: - tool_search

        @Test("tool_search rejects a non-positive limit at the handler")
        func toolSearchNegativeLimitHandler() async throws {
            let deps = ToolDependencies()
            _ = try ArcAgentCore.testRegistry(dependencies: deps)
            let output = try await ToolSearchTool.entry(registry: deps.toolSearchRegistry)
                .handler(["query": "file", "limit": -1])
            #expect(output.hasPrefix("Error:"), "expected a readable error, got: \(output)")
            #expect(output.contains("limit"))
        }

        @Test("tool_search clamps a negative limit, so every caller is safe")
        func toolSearchClampsLimit() {
            let catalog = [
                ToolSearchTool.CatalogEntry(name: "read_file", description: "read a file", toolset: "file"),
                ToolSearchTool.CatalogEntry(name: "write_file", description: "write a file", toolset: "file"),
            ]
            #expect(ToolSearchTool.search(catalog, query: "", limit: -1).isEmpty)
            #expect(ToolSearchTool.search(catalog, query: "file", limit: -1).isEmpty)
        }
    }
}
