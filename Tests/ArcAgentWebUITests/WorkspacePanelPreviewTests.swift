import Foundation
import Testing

@testable import ArcWebUI

/// The right-hand workspace panel's file preview (Hermes parity: the right
/// "workspace" panel shows a file tree AND a preview of the selected file).
/// The pure path-safety rule is unit-tested; the wiring is pinned against the
/// sources (house style for surfaces that load real settings on init).
@Suite("Workspace panel preview")
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

    @Test("the panel body renders the preview and calls the tree for the file list")
    func panelBodyRendersPreview() {
        let views = Self.source("Views.swift")
        #expect(views.contains("func workspaceBodyHTML()"))
        #expect(views.contains("ws-preview"))
        #expect(views.contains("w-preview-back"))
        // The tree branch (no preview open) still emits the breadcrumb + tree.
        #expect(views.contains("workspaceTreeHTML()"))
    }

    @Test("openWorkspaceFile guards traversal via the shared rule")
    func openGuardsViaRule() {
        let actions = Self.source("AppState+Actions.swift")
        #expect(actions.contains("WorkspaceRules.isSafeRelativePath(relPath)"),
                "the preview open must validate through the shared rules, not inline")
    }
}
