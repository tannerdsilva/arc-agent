import Foundation
import Testing

@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The workspace file-tree renderer was the source of the lag spikes: it did
    /// synchronous disk I/O (plus a per-comparison stat) on every shell render,
    /// even when the panel was hidden. The scan moved into a pure, cached
    /// `renderWorkspaceTree` and is skipped entirely while the panel is closed.
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
            let html = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: [])
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
            let hidden = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: [])
            #expect(!hidden.contains(".secret"))
            #expect(hidden.contains("visible.txt"))
            let shown = AppState.renderWorkspaceTree(root: ws, showHidden: true, expanded: [])
            #expect(shown.contains(".secret"))
        }

        @Test("includes children of an expanded folder")
        func expandsFolder() throws {
            let ws = try makeWorkspace(["docs/readme.md", "docs/notes.txt"])
            defer { try? FileManager.default.removeItem(at: ws) }
            let collapsed = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: [])
            #expect(!collapsed.contains("readme.md"))
            let expanded = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: ["docs"])
            #expect(expanded.contains("readme.md"))
            #expect(expanded.contains("notes.txt"))
        }

        @Test("empty workspace renders the empty hint")
        func emptyWorkspace() throws {
            let ws = try makeWorkspace([])
            defer { try? FileManager.default.removeItem(at: ws) }
            let html = AppState.renderWorkspaceTree(root: ws, showHidden: false, expanded: [])
            #expect(html.contains("This workspace is empty."))
        }

        @Test("exposes the render cache clear + fresh scan entry points")
        func exposesCacheSeams() {
            // Source-contract: the render path must skip scanning a hidden panel
            // and the live scanner must use a fresh (uncached) listing.
            let src = Self.read("Views.swift")
            #expect(src.contains("guard workspaceOpen else { return \"\" }"))
            #expect(src.contains("func freshWorkspaceTreeHTML()"))
            #expect(src.contains("func clearWorkspaceTreeCache()"))
            #expect(src.contains("Self.renderWorkspaceTree("))
            let actions = Self.read("AppState+Actions.swift")
            #expect(actions.contains("func scanWorkspaceTree() async -> Bool {\n        let fresh = freshWorkspaceTreeHTML()"))
            #expect(actions.contains("clearWorkspaceTreeCache()"))
        }

        private static func read(_ name: String) -> String {
            (try? String(contentsOfFile: "Sources/ArcWebUI/\(name)", encoding: .utf8)) ?? ""
        }
    }
}
