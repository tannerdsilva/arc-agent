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

        /// A15 (no-webui 2.17.0): the ENGINE owns both the gesture and the
        /// clear. The composer states them on its own open tag; the overlay
        /// registers no Enter handler and no submit clear. What stays is the
        /// one consequence the engine cannot express: its draft store re-fills
        /// an EMPTY `[data-draft-id]` field on the next replacing patch, and
        /// `onDocSubmit` clears the control, not `webui-draft:<identity>` —
        /// measured, the submitted text came back ~1.3 s after Enter. The
        /// overlay's remaining submit listener captures the payload in the
        /// CAPTURE phase (before the engine reads and clears it) so a restored
        /// echo of exactly that text can be cleared again.
        @Test("the composer states submit-on-enter and clear-on-submit; the engine owns the submit path")
        func submitAndClearAreTheEngines() async throws {
            let source = try Self.overlaySource()
            let composer = await RenderedMarkup.composer()
            #expect(
                composer.contains("data-submit-on-enter=\"plain\""),
                "a textarea opts in to Enter-to-submit by VALUE; the bare attribute leaves it exempt"
            )
            #expect(
                composer.contains("data-clear-on-submit"),
                "the engine clears the field on the submit event"
            )
            #expect(
                !source.contains("window.addEventListener('submit'"),
                "the overlay must not clear on submit: the engine's onDocSubmit does"
            )
            #expect(
                source.contains("document.addEventListener('submit'") && source.contains("  }, true);"),
                "the echo guard's memo must be captured before the engine reads and clears the control"
            )
            #expect(
                !source.contains("form.requestSubmit()"),
                "the Enter gesture is the engine's (`data-submit-on-enter=\"plain\"`)"
            )
            #expect(
                !source.contains("e.keyCode === 229"),
                "the IME guard is the engine's; a copy here is a second rule to keep in sync"
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