import Foundation
import Testing

import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The workspace file-tree renderer was the source of the lag spikes: it did
    /// synchronous disk I/O (plus a per-comparison stat) on every shell render,
    /// even when the panel was hidden. The scan moved into a pure, cached
    /// `renderWorkspaceTree` and is skipped entirely while the panel is closed.
    ///
    /// the first four pins render the typed tree; the cache pin is a state
    /// assertion (a hidden panel must leave the cache cold), not a source grep.
    @Suite("Workspace tree render", .serialized)
    struct WorkspaceTreeRenderTests {

        /// Builds a temp workspace with a known layout, returns its URL.
        private func makeWorkspace(_ files: [String]) throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-ws-tree-\(UUID().uuidString)", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files {
                let url = dir.appendingPathComponent(f)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
            return dir
        }

        @Test("lists files and directories, directories first")
        func sortsDirsBeforeFiles() throws {
            let ws = try makeWorkspace(["z.txt", "b.txt", "a-folder/nested.txt", "m-folder/x.txt"])
            defer { try? FileManager.default.removeItem(at: ws) }
            let html = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: []).markup.html
            // directories first (a-folder, m-folder), then files (b.txt, z.txt)
            let aFolder = html.range(of: "a-folder")!
            let mFolder = html.range(of: "m-folder")!
            let bFile = html.range(of: "b.txt")!
            let zFile = html.range(of: "z.txt")!
            #expect(aFolder.lowerBound < bFile.lowerBound)
            #expect(mFolder.lowerBound < bFile.lowerBound)
            #expect(bFile.lowerBound < zFile.lowerBound)
            // nested files not shown until the folder is expanded
            #expect(!html.contains("nested.txt"))
        }

        @Test("hides dotfiles unless showHidden is set")
        func hidesDotfiles() throws {
            let ws = try makeWorkspace([".secret", "visible.txt"])
            defer { try? FileManager.default.removeItem(at: ws) }
            let hidden = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: []).markup.html
            #expect(!hidden.contains(".secret"))
            #expect(hidden.contains("visible.txt"))
            let shown = AppState.renderWorkspaceTree(root: ws, showHidden: true, expanded: []).markup.html
            #expect(shown.contains(".secret"))
        }

        @Test("includes children of an expanded folder")
        func expandsFolder() throws {
            let ws = try makeWorkspace(["docs/readme.md", "docs/notes.txt"])
            defer { try? FileManager.default.removeItem(at: ws) }
            let collapsed = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: []).markup.html
            #expect(!collapsed.contains("readme.md"))
            let expanded = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: ["docs"]).markup.html
            #expect(expanded.contains("readme.md"))
            #expect(expanded.contains("notes.txt"))
        }

        @Test("empty workspace renders the empty hint")
        func emptyWorkspace() throws {
            let ws = try makeWorkspace([])
            defer { try? FileManager.default.removeItem(at: ws) }
            let html = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: []).markup.html
            #expect(html.contains("This workspace is empty."))
        }

        @Test("a hidden panel does not scan the directory")
        func hiddenPanelSkipsScan() async {
            // the render path must skip the synchronous disk walk while the panel
            // is closed: the shell re-renders the panel on every push, and the
            // scan was the lag spike. asserted on state — a scan would warm the
            // render cache, so a cold cache is the proof it never ran.
            var fixture = AppState.RenderFixture()
            fixture.settings.workspaces = [WorkspaceEntry(name: "pin", path: "/arc/ws-tree-never-scanned")]
            fixture.settings.activeWorkspace = "pin"
            fixture.workspaceOpen = false
            let app = AppState(renderFixture: fixture)
            let html = await app.workspaceBodyHTML().markup.html
            #expect(html.isEmpty, "a closed panel renders no body")
            #expect(await app.workspaceTreeCacheKey == nil,
                    "a closed panel must not scan the directory")
        }

        @Test("exposes the render cache clear + fresh scan entry points")
        func exposesCacheSeams() {
            // Source-contract: the live scanner must use a fresh (uncached)
            // listing, and both entry points must keep existing.
            let src = Self.read("Views.swift")
            #expect(src.contains("func freshWorkspaceTreeHTML()"))
            #expect(src.contains("func clearWorkspaceTreeCache()"))
            #expect(src.contains("render(Self.renderWorkspaceTree("),
                    "the fresh scan must render the typed tree, not a second string builder")
            let actions = Self.read("AppState+Actions.swift")
            #expect(actions.contains("func scanWorkspaceTree() async -> Bool {\n        let fresh = freshWorkspaceTreeHTML()"))
            #expect(actions.contains("clearWorkspaceTreeCache()"))
        }

        private static func read(_ name: String) -> String {
            (try? String(contentsOfFile: "Sources/ArcWebUI/\(name)", encoding: .utf8)) ?? ""
        }
    }
}