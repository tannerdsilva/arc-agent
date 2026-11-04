import Foundation
import Testing

@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The client half of the streaming upload: one `XMLHttpRequest` per file,
    /// the raw `File` object as the body, progress from `xhr.upload.onprogress`.
    ///
    /// Read from `AppShell.Assets.overlay.bytes` — the bytes the daemon actually
    /// serves — not from the source file, so this guard cannot pass on an embed
    /// that stopped tracking `Assets/overlay.js`.
    @Suite("upload client contract", .serialized)
    struct UploadClientContractTests {

        private static var overlay: String {
            String(decoding: AppShell.Assets.overlay.bytes, as: UTF8.self)
        }

        @Test("the overlay streams uploads and keeps no base64 form")
        func overlayStreamsUploads() {
            let js = Self.overlay
            #expect(
                !js.contains("readFileAsB64"),
                """
                the overlay still carries the FileReader/base64 upload path: a file \
                must reach the server as bytes, never as a JavaScript string
                """
            )
            #expect(
                !js.contains("ws-upload-form"),
                """
                the hidden upload form is back: uploads are one XMLHttpRequest per \
                file, not a form submit with three hidden inputs
                """
            )
            #expect(
                js.contains("XMLHttpRequest"),
                """
                the overlay must post the File with XMLHttpRequest — fetch exposes \
                no upload progress, and a multi-GB transfer must show its progress
                """
            )
            #expect(
                js.contains("upload.onprogress"),
                """
                without xhr.upload.onprogress the progress row cannot move: the \
                whole transfer is a black box again
                """
            )
            #expect(
                js.contains("'/api/upload'") || js.contains("\"/api/upload\""),
                "the upload must address the streaming route `POST /api/upload`"
            )
            #expect(
                js.contains("workspace-refresh"),
                """
                the refresh seam is gone: an HTTP upload returns no \
                FragmentUpdate, so the tree repaints only when the client asks \
                for the wired `workspace-refresh` render after a 200
                """
            )
        }
    }
}
