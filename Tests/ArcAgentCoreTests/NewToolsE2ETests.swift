import Foundation
import Testing
@testable import ArcAgentCore

/// Shared helper namespace for tool tests.
enum SearchFilesToolTests {}

/// Sendable capture box for tests (actor-isolated, First-Law compliant).
actor CaptureBox {
    private var value: String = ""
    func set(_ v: String) { value = v }
    func get() -> String { value }
}

/// End-to-end tests for the three new tools against the real filesystem,
/// real ripgrep, and real python3. Serialized: execute_code tests share the
/// ambient RPC dispatcher actor, so they must not interleave.
@Suite("New tools E2E", .serialized)
struct NewToolsE2ETests {

    // MARK: - Fixtures

    private static func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-tool-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - patch tool (replace mode)

    @Test("patch replace applies an edit and returns a diff")
    func patchReplaceApplies() async throws {
        let dir = try Self.tempDir("patch-replace")
        let file = dir.appendingPathComponent("sample.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await PatchTool.entry.handler([
            "mode": "replace", "path": file.path,
            "old_string": "world", "new_string": "Swift",
        ])
        #expect(result.contains("Successfully applied"))
        #expect(result.contains("-hello world"))
        #expect(result.contains("+hello Swift"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello Swift")
    }

    @Test("patch replace refuses ambiguous matches without replace_all")
    func patchReplaceAmbiguous() async throws {
        let dir = try Self.tempDir("patch-ambiguous")
        let file = dir.appendingPathComponent("sample.txt")
        try "a a a".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await PatchTool.entry.handler([
            "mode": "replace", "path": file.path,
            "old_string": "a", "new_string": "b",
        ])
        #expect(result.contains("Found 3 matches"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "a a a")
    }

    @Test("patch replace with replace_all replaces every occurrence")
    func patchReplaceAll() async throws {
        let dir = try Self.tempDir("patch-all")
        let file = dir.appendingPathComponent("sample.txt")
        try "a b a b".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await PatchTool.entry.handler([
            "mode": "replace", "path": file.path, "old_string": "a",
            "new_string": "x", "replace_all": true,
        ])
        #expect(result.contains("(2 matches)"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "x b x b")
    }

    @Test("patch replace survives whitespace drift via fuzzy strategies")
    func patchFuzzyWhitespace() async throws {
        let dir = try Self.tempDir("patch-fuzzy")
        let file = dir.appendingPathComponent("sample.txt")
        try "let x  =  1".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await PatchTool.entry.handler([
            "mode": "replace", "path": file.path,
            "old_string": "let x = 1", "new_string": "let x = 2",
        ])
        #expect(result.contains("fuzzy matched with"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "let x = 2")
    }

    @Test("patch replace preserves CRLF line endings")
    func patchPreservesCRLF() async throws {
        let dir = try Self.tempDir("patch-crlf")
        let file = dir.appendingPathComponent("sample.txt")
        try "one\r\ntwo\r\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await PatchTool.entry.handler([
            "mode": "replace", "path": file.path,
            "old_string": "two", "new_string": "TWO",
        ])
        let bytes = try Data(contentsOf: file)
        #expect(bytes == Data("one\r\nTWO\r\n".utf8))
    }

    @Test("patch replace reports already-applied patches")
    func patchAlreadyApplied() async throws {
        let dir = try Self.tempDir("patch-applied")
        let file = dir.appendingPathComponent("sample.txt")
        try "already new here".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await PatchTool.entry.handler([
            "mode": "replace", "path": file.path,
            "old_string": "stale text", "new_string": "already new here",
        ])
        #expect(result.contains("already been applied"))
    }

    // MARK: - patch tool (V4A mode)

    @Test("patch V4A mode applies a multi-file patch")
    func patchV4AMode() async throws {
        let dir = try Self.tempDir("patch-v4a")
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try "old content".write(to: a, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let v4a = """
        *** Begin Patch
        *** Update File: \(a.path)
        @@ marker @@
        -old content
        +new content
        *** Add File: \(b.path)
        +fresh file
        *** End Patch
        """
        let result = try await PatchTool.entry.handler([
            "mode": "patch", "patch": v4a,
        ])
        #expect(result.contains("Successfully applied V4A patch"))
        #expect(result.contains("Created:"))
        #expect(try String(contentsOf: a, encoding: .utf8) == "new content")
        #expect(try String(contentsOf: b, encoding: .utf8) == "fresh file")
    }

    @Test("patch V4A mode validates atomically on failure")
    func patchV4AAtomic() async throws {
        let dir = try Self.tempDir("patch-v4a-atomic")
        let a = dir.appendingPathComponent("a.txt")
        try "old content".write(to: a, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let v4a = """
        *** Begin Patch
        *** Update File: \(a.path)
        @@ marker @@
        -old content
        +new content
        *** Update File: does-not-exist.txt
        -nope
        +nope2
        *** End Patch
        """
        let result = try await PatchTool.entry.handler([
            "mode": "patch", "patch": v4a,
        ])
        #expect(result.contains("Error:"))
        #expect(result.contains("validation failed"))
        #expect(try String(contentsOf: a, encoding: .utf8) == "old content")
    }

    // MARK: - search_files tool

    @Test("search_files finds content with line numbers (JSON shape)")
    func searchContent() async throws {
        let dir = try Self.tempDir("search-content")
        let f = dir.appendingPathComponent("code.py")
        try "def foo():\n    return 42\n".write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await SearchFilesTool.search(
            pattern: "return 42", path: dir.path, target: "content",
            fileGlob: nil, limit: 50, offset: 0, outputMode: "content", context: 0)
        #expect(result.contains("\"total_count\":1"))
        #expect(result.contains("code.py"))
        #expect(result.contains("\"line\":2"))
        #expect(result.contains("return 42"))
    }

    @Test("search_files files_only lists paths")
    func searchFilesOnly() async throws {
        let dir = try Self.tempDir("search-files-only")
        try "x".write(to: dir.appendingPathComponent("one.py"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await SearchFilesTool.search(
            pattern: "*.py", path: dir.path, target: "files",
            fileGlob: nil, limit: 50, offset: 0, outputMode: "files_only", context: 0)
        #expect(result.contains("\"files\""))
        #expect(result.contains("one.py"))
        #expect(result.contains("two.py") == false)
    }

    @Test("search_files count mode reports per-file counts")
    func searchCount() async throws {
        let dir = try Self.tempDir("search-count")
        try "alpha beta\nalpha\n".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await SearchFilesTool.search(
            pattern: "alpha", path: dir.path, target: "content",
            fileGlob: "*.txt", limit: 50, offset: 0, outputMode: "count", context: 0)
        #expect(result.contains("\"counts\""))
        #expect(result.contains(":2"))
    }

    @Test("search_files finds files by glob (mtime order)")
    func searchFilesMode() async throws {
        let dir = try Self.tempDir("search-files")
        try "x".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("other.yaml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await SearchFilesTool.search(
            pattern: "*.json", path: dir.path, target: "files",
            fileGlob: nil, limit: 50, offset: 0, outputMode: "content", context: 0)
        #expect(result.contains("config.json"))
        #expect(result.contains("other.yaml") == false)
    }

    @Test("search_files supports offset pagination")
    func searchPagination() async throws {
        let dir = try Self.tempDir("search-page")
        for n in 0..<3 {
            try "needle".write(to: dir.appendingPathComponent("f\(n)"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let page2 = try await SearchFilesTool.search(
            pattern: "needle", path: dir.path, target: "content",
            fileGlob: nil, limit: 1, offset: 1, outputMode: "files_only", context: 0)
        #expect(page2.contains("\"truncated\":true"))
    }

    @Test("search_files missing path reports similar paths")
    func searchMissingPath() async throws {
        let result = try await SearchFilesTool.search(
            pattern: "x", path: "/nonexistent-dir-xyz", target: "content",
            fileGlob: nil, limit: 50, offset: 0, outputMode: "content", context: 0)
        #expect(result.contains("Path not found"))
    }

    // MARK: - execute_code tool

    @Test("execute_code runs a script and returns stdout", .serialized)
    func executeRuns() async throws {
        await ExecuteCodeTool.dispatcher.setHost { name, args in
            "tool:\(name):\(args.description)"
        }
        defer { ExecuteCodeTool.timeoutOverride = nil }
        let result = try await ExecuteCodeTool.entry.handler([
            "code": "print('hello from python')",
        ])
        #expect(result.contains("\"status\":\"success\""))
        #expect(result.contains("hello from python"))
        #expect(result.contains("\"exit_code\":0"))
    }

    @Test("execute_code dispatches tools over RPC into the host", .serialized)
    func executeDispatches() async throws {
        let capture = CaptureBox()
        await ExecuteCodeTool.dispatcher.setHost { name, args in
            await capture.set("\(name)|\(args["path"] ?? "")")
            return "CONTENT"
        }
        defer { ExecuteCodeTool.timeoutOverride = nil }
        let result = try await ExecuteCodeTool.entry.handler([
            "code": "from hermes_tools import read_file\n"
                + "print(read_file('/tmp/fake.txt'))",
        ])
        #expect(await capture.get() == "read_file|/tmp/fake.txt")
        #expect(result.contains("CONTENT"))
        #expect(result.contains("\"tool_calls_made\":1"))
    }

    @Test("execute_code reports non-zero exits with stderr", .serialized)
    func executeError() async throws {
        await ExecuteCodeTool.dispatcher.setHost { _, _ in "" }
        defer { ExecuteCodeTool.timeoutOverride = nil }
        let result = try await ExecuteCodeTool.entry.handler([
            "code": "import sys\nprint('partial')\nsys.stderr.write('boom traceback')\nsys.exit(3)",
        ])
        #expect(result.contains("\"status\":\"error\""))
        #expect(result.contains("boom traceback"))
        #expect(result.contains("--- stderr ---"))
    }

    @Test("execute_code kills long-running scripts on timeout", .serialized)
    func executeTimeout() async throws {
        await ExecuteCodeTool.dispatcher.setHost { _, _ in "" }
        ExecuteCodeTool.timeoutOverride = 2
        defer { ExecuteCodeTool.timeoutOverride = nil }
        let result = try await ExecuteCodeTool.entry.handler([
            "code": "print('started')\nimport time\ntime.sleep(60)",
        ])
        #expect(result.contains("\"status\":\"timeout\""))
        #expect(result.contains("timed out"))
    }

    @Test("execute_code budget blocks the 51st tool call", .serialized)
    func executeBudget() async throws {
        await ExecuteCodeTool.dispatcher.setHost { name, _ in
            name  // any tool returns
        }
        defer { ExecuteCodeTool.timeoutOverride = nil }
        let calls = (0..<51).map { _ in "read_file('/tmp/x\(UUID().uuidString)')" }
            .joined(separator: "\n")
        let result = try await ExecuteCodeTool.entry.handler([
            "code": "from hermes_tools import read_file\n" + calls,
        ])
        #expect(result.contains("Tool-call budget exceeded"))
    }
}
