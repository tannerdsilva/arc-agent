import Foundation
import Testing
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// Composer drag & drop / paste attachments, pinned against the sources
    /// (house style for wiring contracts not reachable as pure units):
    /// - files dropped on the composer upload through the `composer-attach`
    ///   wire and are attached server-side (no /api/upload round-trip);
    /// - the server writes into the active chat's workspace under
    ///   `attachments/` and calls `addAttachment` with the ABSOLUTE path
    ///   (describeImage reads `URL(fileURLWithPath:)`, so relative paths
    ///   would silently produce empty descriptions);
    /// - the collapsed workspace dock (`#ws-dock`) is a drop target too.
    ///
    /// regression context (2026-10-30): the paste handler posted to
    /// `/api/upload`, an endpoint that never existed — every image paste
    /// failed silently. The composer now shares the workspace-upload
    /// transport (hidden form + WS submit), and drag-drop was missing
    /// entirely (Hermes parity).
    @Suite("Composer attach drop/paste contract", .serialized)
    struct ComposerAttachTests {

        private static func overlay() -> String {
            (try? String(contentsOfFile: "Sources/ArcWebUI/Assets/overlay.js", encoding: .utf8)) ?? ""
        }

        private static func source(_ name: String) -> String {
            (try? String(contentsOfFile: "Sources/ArcWebUI/\(name)", encoding: .utf8)) ?? ""
        }

        private static func chrome() -> String {
            (try? String(contentsOfFile: "Sources/ArcTheme/ChromeSheet.swift", encoding: .utf8)) ?? ""
        }

        // MARK: - Client wiring

        @Test("composer drop targets the composer form")
        func composerDropWiring() {
            let js = Self.overlay()
            #expect(js.contains("closest('#composer-form')"),
                    "the drop/dragover pair must scope to the composer form")
            #expect(js.contains("sendComposerUpload"),
                    "drops must flow through the shared composer upload")
            #expect(js.contains("collectEntry(entry, 'attachments/'"),
                    "dropped folders keep their structure under attachments/")
        }

        @Test("the upload form speaks the composer-attach wire")
        func uploadFormUsesWire() {
            let js = Self.overlay()
            #expect(js.contains("composer-upload-form"))
            #expect(js.contains("data-component-id', 'composer-attach'"),
                    "the hidden form must target the composer-attach component")
            #expect(js.contains("[name=\"upl-rel\"]"),
                    "the rel-path field name must match the wire's extractor")
        }

        @Test("image paste no longer posts to the nonexistent /api/upload")
        func pasteUsesSharedUpload() {
            let js = Self.overlay()
            #expect(!js.contains("/api/upload"),
                    "the endpoint never existed; every paste failed silently")
            #expect(js.contains("imgs.forEach(function (f) { sendComposerUpload(f); })"))
        }

        @Test("the collapsed workspace dock accepts drops")
        func dockIsDropTarget() {
            let js = Self.overlay()
            #expect(js.contains("closest('#ws-panel, #ws-dock')"),
                    "the dock must be a drop target while the panel is closed")
            #expect(js.contains("'#ws-panel, #ws-dock'"),
                    "drag highlight cleanup must cover both surfaces")
        }

        // MARK: - Server wiring

        @Test("the composer-attach wire routes to composerAttachUpload")
        func wireRoutesToAppState() {
            let actions = Self.source("Actions.swift")
            #expect(actions.contains("@Wired(\"composer-attach\", events: [.submit])"))
            #expect(actions.contains("app.composerAttachUpload(name: name, relPath: rel, b64: b64)"))
        }

        @Test("composerAttachUpload validates paths and attaches the absolute destination")
        func serverSideContract() {
            let src = Self.source("AppState+Actions.swift")
            #expect(src.contains("!rel.components(separatedBy: \"/\").contains(\"..\")"),
                    "traversal must be rejected like uploadWorkspaceFile")
            #expect(src.contains("appendingPathComponent(\"attachments\")"),
                    "uploads land under attachments/ in the active workspace")
            #expect(src.contains("addAttachment(final.path)"),
                    "the absolute destination path must be attached, not the relative one")
            #expect(src.contains("clearWorkspaceTreeCache()"),
                    "the workspace tree must refresh after an upload")
            #expect(!src.contains("data.count <= 10 * 1024 * 1024"),
                    "uploads are uncapped — no server-side size guard (user request)")
        }

        @Test("the composer drag highlight is themed")
        func dragHighlightThemed() {
            #expect(Self.chrome().contains(".composer-bar.drag"),
                    "the drop affordance must use the accent token")
            #expect(Self.chrome().contains("#ws-dock.drag"))
        }
    }
}
