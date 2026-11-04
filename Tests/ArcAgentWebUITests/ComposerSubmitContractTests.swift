import Foundation
import Testing

@testable import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The overlay's composer handling must cooperate with the ENGINE's event
    /// delegation (document-level, bubble, registered when the engine script
    /// runs). The submit-time clear is the order-sensitive one: registered on
    /// `document` it runs BEFORE the engine reads the field — because the overlay
    /// registers first — and every send carries `""` (measured live 2026-10-01:
    /// submit frames showed `{"composer-input": ""}` with a filled textarea).
    @Suite("Composer submit contract", .serialized)
    struct ComposerSubmitContractTests {

        private static func overlaySource() throws -> String {
            let path = "Sources/ArcWebUI/Assets/overlay.js"
            return try String(contentsOfFile: path, encoding: .utf8)
        }

        @Test("the submit clear runs after the engine's read (window, not document)")
        func clearRunsAfterEngineRead() throws {
            let source = try Self.overlaySource()
            #expect(
                source.contains("window.addEventListener('submit'"),
                """
                the composer clear must register on window: the engine's delegated \
                submit listener lives on document, and a document-level clear \
                (registered earlier) erases the value before the engine reads it
                """
            )
            #expect(
                !source.contains("document.addEventListener('submit'"),
                """
                a document-level submit listener runs before the engine's own and \
                would clear the composer before the engine reads it — every send \
                then carries an empty field
                """
            )
        }

        /// A builtin slash command runs locally: nothing downstream consumes the
        /// draft the way a turn does, so the send path clears it itself. Without
        /// that, the command stays in the composer and the next Enter runs it a
        /// second time (measured in the app: `/help` twice = two transcript rows).
        @Test("a builtin slash command consumes the composer draft")
        func builtinConsumesTheDraft() async throws {
            var fixture = AppState.RenderFixture()
            fixture.activeSessionID = "sess-slash"
            let app = AppState(renderFixture: fixture)
            let controller = Controller(app: app, push: { _ in })

            await app.storeComposerDraft("/usage", sessionID: "sess-slash")
            _ = await controller.submitChat(text: "/usage")

            let drafts = await app.settings.composerDrafts
            #expect((drafts["sess-slash"] ?? "").isEmpty,
                    "the command stayed in the composer: \(drafts["sess-slash"] ?? "nil")")
        }

        /// The submit guard compares the text the field held with the text that
        /// was sent. The slash palette completes `/help` to `/help `, and the
        /// trailing space used to slip past an exact-match guard: the draft came
        /// back after the client had already cleared the composer.
        @Test("the draft guard ignores a whitespace-only difference")
        func guardComparesTrimmedText() async throws {
            let app = AppState(renderFixture: .init())

            await app.noteSubmittedDraft("/help", sessionID: "sess-guard")
            await app.storeComposerDraft("/help ", sessionID: "sess-guard")

            let drafts = await app.settings.composerDrafts
            #expect(drafts["sess-guard"] == nil,
                    "the padded spelling resurrected the sent draft: \(drafts["sess-guard"] ?? "nil")")
        }
    }
}