import Foundation
import Testing
@testable import ArcAgentCore

/// Hermes `_resolve_path_for_task` / `_path_resolution_warning` parity:
/// relative tool paths anchor to the conversation's workspace root, and a
/// relative path that escapes it is surfaced as a warning — never a silent
/// read/edit of a different checkout.
@Suite("Workspace path anchoring")
struct WorkspacePathTests {

    // MARK: - Fixtures

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-wsp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Resolver

    @Test("relative paths resolve against the bound workspace root")
    func resolveAnchorsToRoot() throws {
        let root = makeRoot().path
        try WorkspacePath.$root.withValue(root) {
            #expect(WorkspacePath.resolve("a/b.txt") == root + "/a/b.txt")
            #expect(WorkspacePath.resolve("./x.txt") == root + "/x.txt")
            #expect(WorkspacePath.resolve("a/../b.txt") == root + "/b.txt")
        }
    }

    @Test("absolute and home-relative paths pass through untouched")
    func resolveAbsolute() throws {
        let root = makeRoot().path
        try WorkspacePath.$root.withValue(root) {
            #expect(WorkspacePath.resolve("/etc/hosts") == "/etc/hosts")
            #expect(WorkspacePath.resolve("~/nonexistent-file") ==
                (FileManager.default.homeDirectoryForCurrentUser.path) + "/nonexistent-file")
        }
    }

    @Test("no bound root keeps process-relative behavior")
    func resolveWithoutRoot() throws {
        let cwd = FileManager.default.currentDirectoryPath
        try WorkspacePath.$root.withValue(nil) {
            #expect(WorkspacePath.resolve("foo.txt") == cwd + "/foo.txt")
        }
    }

    // MARK: - Divergence warning

    @Test("warning fires only for relative paths that escape the root")
    func divergenceCases() throws {
        let root = makeRoot().path
        try WorkspacePath.$root.withValue(root) {
            #expect(WorkspacePath.divergenceWarning(original: "a.txt", resolved: root + "/a.txt") == nil)
            #expect(WorkspacePath.divergenceWarning(original: "sub/b.txt", resolved: root + "/sub/b.txt") == nil)
            #expect(WorkspacePath.divergenceWarning(original: "a.txt", resolved: root) == nil)
            let w = WorkspacePath.divergenceWarning(original: "../x.txt", resolved: root + "/../x.txt")
            #expect(w != nil)
            #expect(w!.contains("OUTSIDE the active workspace"))
            #expect(WorkspacePath.divergenceWarning(original: "/etc/hosts", resolved: "/etc/hosts") == nil)
        }
        try WorkspacePath.$root.withValue(nil) {
            #expect(WorkspacePath.divergenceWarning(original: "../x.txt", resolved: "/x") == nil)
        }
    }

    // MARK: - Tool-level anchoring

    @Test("read_file anchors relative paths and warns on escape")
    func readAnchors() async throws {
        let root = makeRoot()
        try? "hello-anchored".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "outside-content".write(to: root.deletingLastPathComponent().appendingPathComponent("esc.txt"), atomically: true, encoding: .utf8)

        let inside = try await WorkspacePath.$root.withValue(root.path) {
            try await ReadFileTool.entry.handler(["path": "a.txt"])
        }
        #expect(inside.contains("hello-anchored"))
        #expect(!inside.contains("OUTSIDE"))

        let outside = try await WorkspacePath.$root.withValue(root.path) {
            try await ReadFileTool.entry.handler(["path": "../esc.txt"])
        }
        #expect(outside.contains("outside-content"))
        #expect(outside.contains("OUTSIDE the active workspace"))
    }

    @Test("write_file lands relative paths in the workspace and warns on escape")
    func writeAnchors() async throws {
        let root = makeRoot()
        let inside = try await WorkspacePath.$root.withValue(root.path) {
            try await WriteFileTool.entry.handler(["path": "written.txt", "content": "data"])
        }
        #expect(inside.contains(root.path + "/written.txt"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("written.txt").path))
        #expect(!inside.contains("OUTSIDE"))

        let outside = try await WorkspacePath.$root.withValue(root.path) {
            try await WriteFileTool.entry.handler(["path": "../esc-write.txt", "content": "data"])
        }
        #expect(outside.contains("OUTSIDE the active workspace"))
    }

    @Test("patch (replace) anchors and warns on escape")
    func patchAnchors() async throws {
        let root = makeRoot()
        try? "alpha\nbeta\n".write(to: root.appendingPathComponent("patchme.txt"), atomically: true, encoding: .utf8)
        let inside = try await WorkspacePath.$root.withValue(root.path) {
            try await PatchTool.entry.handler([
                "mode": "replace", "path": "patchme.txt",
                "old_string": "alpha", "new_string": "gamma",
            ])
        }
        #expect(inside.contains("Successfully applied patch"))
        #expect(!inside.contains("OUTSIDE"))
        let patched = try String(contentsOf: root.appendingPathComponent("patchme.txt"), encoding: .utf8)
        #expect(patched == "gamma\nbeta\n")

        let outside = try await WorkspacePath.$root.withValue(root.path) {
            try await PatchTool.entry.handler([
                "mode": "replace", "path": "../patchme-esc.txt",
                "old_string": "zzz", "new_string": "yyy",
            ])
        }
        // File does not exist → not-found error; no workspace warning expected
        // because the error fires before the write. The warning surfaces on
        // write; verify via V4A below too.
        #expect(outside.contains("Error"))
    }

    @Test("V4A patch mode resolves header paths in the workspace and collects warnings")
    func v4aAnchors() async throws {
        let root = makeRoot()
        let inside = try await WorkspacePath.$root.withValue(root.path) {
            try await PatchTool.entry.handler([
                "mode": "patch",
                "patch": """
                *** Begin Patch
                *** Add File: v4a-created.txt
                @@
                +hello-v4a
                *** End Patch
                """,
            ])
        }
        #expect(inside.contains("Successfully applied V4A patch"))
        #expect(!inside.contains("OUTSIDE"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("v4a-created.txt").path))

        let outside = try await WorkspacePath.$root.withValue(root.path) {
            try await PatchTool.entry.handler([
                "mode": "patch",
                "patch": """
                *** Begin Patch
                *** Add File: ../v4a-esc.txt
                @@
                +esc-data
                *** End Patch
                """,
            ])
        }
        #expect(outside.contains("OUTSIDE the active workspace"))
    }

    @Test("search_files anchors its path and warns on escape")
    func searchAnchors() async throws {
        let root = makeRoot()
        try? "needle-in-root".write(to: root.appendingPathComponent("searchme.txt"), atomically: true, encoding: .utf8)
        let inside = try await WorkspacePath.$root.withValue(root.path) {
            try await SearchFilesTool.entry.handler([
                "pattern": "needle-in-root", "path": ".", "target": "content",
            ])
        }
        #expect(inside.contains("needle-in-root"))
        #expect(!inside.contains("OUTSIDE"))

        let outside = try await WorkspacePath.$root.withValue(root.path) {
            try await SearchFilesTool.entry.handler([
                "pattern": "needle-in-root", "path": "..", "target": "content",
            ])
        }
        #expect(outside.contains("OUTSIDE the active workspace"))
    }

    @Test("terminal defaults its working directory to the workspace root")
    func terminalCwdAnchors() async throws {
        let root = makeRoot().path
        let result = try await WorkspacePath.$root.withValue(root) {
            try await TerminalTool.entry.handler(["command": "pwd"])
        }
        #expect(result.contains(root))
        #expect(result.contains("exit_code: 0"))
    }
}
