import Foundation
import Testing

import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The right-hand workspace panel's file preview (Hermes parity: the right
    /// "workspace" panel shows a file tree AND a preview of the selected file).
    /// The pure path-safety rule is unit-tested; the panel body is now asserted
    /// on rendered bytes.
    @Suite("Workspace panel preview", .serialized)
    struct WorkspacePanelPreviewTests {

        // MARK: - Pure path-safety rule

        @Test("safe relative paths are accepted")
        func safePathsAccepted() {
            #expect(WorkspaceRules.isSafeRelativePath("notes.txt"))
            #expect(WorkspaceRules.isSafeRelativePath("src/main.swift"))
            #expect(WorkspaceRules.isSafeRelativePath("a/b/c.md"))
        }

        @Test("traversal and absolute paths are rejected")
        func unsafePathsRejected() {
            #expect(!WorkspaceRules.isSafeRelativePath("../secret"))
            #expect(!WorkspaceRules.isSafeRelativePath("a/../../etc/passwd"))
            #expect(!WorkspaceRules.isSafeRelativePath("/etc/passwd"))
            #expect(!WorkspaceRules.isSafeRelativePath(""))
            #expect(!WorkspaceRules.isSafeRelativePath(".."))
        }

        // MARK: - Wiring contracts (source-pinned)

        private static func source(_ name: String) -> String {
            (try? String(contentsOfFile: "Sources/ArcWebUI/\(name)", encoding: .utf8)) ?? ""
        }

        @Test("clicking a file opens the preview, not a hint toast")
        func fileClickOpensPreview() {
            let actions = Self.source("Actions.swift")
            #expect(actions.contains("app.openWorkspaceFile(path)"),
                    "w-file- must route to openWorkspaceFile")
            #expect(!actions.contains("hint(\"Workspace file:"),
                    "the placeholder hint toast must be gone")
            #expect(actions.contains("w-preview-back") && actions.contains("closeWorkspacePreview()"),
                    "a back affordance must close the preview")
        }

        @Test("openWorkspaceFile guards traversal via the shared rule")
        func openGuardsViaRule() {
            let actions = Self.source("AppState+Actions.swift")
            #expect(actions.contains("WorkspaceRules.isSafeRelativePath(relPath)"),
                    "the preview open must validate through the shared rules, not inline")
        }

        // MARK: - The panel body, rendered

        /// a real folder so the tree branch has rows to emit.
        private func makeWorkspace() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-ws-panel-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
            return dir
        }

        private func app(root: URL, preview: String? = nil, content: String? = nil) -> AppState {
            var fixture = AppState.RenderFixture()
            fixture.settings.workspaces = [WorkspaceEntry(name: "pin", path: root.path)]
            fixture.settings.activeWorkspace = "pin"
            fixture.workspaceOpen = true
            fixture.previewPath = preview
            fixture.previewContent = content
            return AppState(renderFixture: fixture)
        }

        @Test("the panel body renders the preview and calls the tree for the file list")
        func panelBodyRendersPreview() async throws {
            let root = try makeWorkspace()
            defer { try? FileManager.default.removeItem(at: root) }

            let preview = await app(root: root, preview: "notes.txt", content: "hello")
                .workspaceBodyHTML().markup.html
            #expect(preview.contains("class=\"ws-preview\""), "an open file renders the preview pane")
            #expect(preview.contains("id=\"w-preview-back\""), "the preview must offer a way back")
            #expect(preview.contains("id=\"ws-preview-copy\""), "the preview must keep its copy control")
            #expect(preview.contains("<pre class=\"ws-preview-body\">hello</pre>"), "a text preview is escaped into a pre")
            #expect(!preview.contains("class=\"ws-path\""), "the preview replaces the tree, it does not sit beside it")

            // the tree branch (no preview open) still emits the breadcrumb + the rows
            let tree = await app(root: root).workspaceBodyHTML().markup.html
            #expect(tree.contains("class=\"ws-path\""), "no preview: the breadcrumb comes back")
            #expect(tree.contains("id=\"w-file-"), "no preview: the file list is the body")
            #expect(!tree.contains("class=\"ws-preview\""), "no preview: no preview pane")
        }
    }
}