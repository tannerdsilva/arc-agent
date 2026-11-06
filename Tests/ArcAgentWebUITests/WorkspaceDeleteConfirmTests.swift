import Foundation
import Testing
import WebUI
@testable import ArcWebUI

/// Workspace tree rows carry a hover-revealed X that arms the shared
/// confirmation dialog; only a confirmed Delete removes the entry, and the
/// delete path refuses anything that escapes the workspace root.
@Suite("Workspace delete confirmation", .serialized)
struct WorkspaceDeleteConfirmTests {

    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-ws-del-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: dir.appendingPathComponent("sub").appendingPathComponent("inner.txt"))
        return dir
    }

    private func app(root: URL) -> AppState {
        var fixture = AppState.RenderFixture()
        fixture.settings.workspaces = [WorkspaceEntry(name: "pin", path: root.path)]
        fixture.settings.activeWorkspace = "pin"
        fixture.workspaceOpen = true
        return AppState(renderFixture: fixture)
    }

    @Test("tree rows render a hover delete control")
    func rowsRenderDeleteX() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let html = await app(root: root).workspaceBodyHTML().markup.html
        #expect(html.contains("class=\"ws-del\""), "every row carries the X control")
        #expect(html.contains("id=\"w-del-"), "the X reports its own targetId")
    }

    @Test("arming a file asks about the file; arming a folder asks about the folder")
    func armDescribesTheEntry() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = app(root: root)
        await a.armWorkspaceEntryDelete("notes.txt")
        var req = await a.pendingConfirm
        #expect(req?.kind == "ws-delete")
        #expect(req?.title == "Delete file?")
        #expect(req?.body.contains("notes.txt") == true)

        await a.armWorkspaceEntryDelete("sub")
        req = await a.pendingConfirm
        #expect(req?.title == "Delete folder?")
        #expect(req?.body.contains("everything inside it") == true)
    }

    @Test("confirmed delete removes the entry and refuses traversal")
    func deleteRemovesOnlyInsideTheRoot() async throws {
        let root = try makeWorkspace()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-ws-del-outside-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let a = app(root: root)
        await a.deleteWorkspaceEntry("notes.txt")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.txt").path))

        // traversal never escapes the workspace root
        await a.deleteWorkspaceEntry("../\(outside.lastPathComponent)")
        #expect(FileManager.default.fileExists(atPath: outside.path), "the outside file must survive")
        await a.deleteWorkspaceEntry(outside.path)
        #expect(FileManager.default.fileExists(atPath: outside.path), "absolute paths must be refused")

        // nested folder goes with its contents
        await a.deleteWorkspaceEntry("sub")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sub").path))
    }
}
