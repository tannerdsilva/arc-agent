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

        /// A15 (no-webui 2.17.0) + A16d (3.1.0): the ENGINE owns the gesture, the
        /// clear and the draft store. `data-submit-on-enter="plain"` submits,
        /// `data-clear-on-submit` empties the field, and 3.1.0's `onDocSubmit`
        /// drops `webui-draft:<identity>` for a cleared
        /// `[data-clear-on-submit][data-draft-id]` control — so the post-submit
        /// replacing patch can no longer hand the sent text back. Arc's half is
        /// the two attributes on the composer's open tag; the overlay registers
        /// no submit listener at all (the A15 capture-phase echo guard is
        /// deleted with the seam it fed).
        @Test("the composer states submit-on-enter and clear-on-submit; the engine owns the submit path")
        func submitAndClearAreTheEngines() async {
            // A17 deleted the client file, so the negative half of this pin is
            // structural now (`ZeroClientScriptTests`: no `.js` under Sources at
            // all, which covers the submit listener, the echo guard, the
            // requestSubmit path and the IME copy at once). What arc still owns
            // is the two attributes on the composer's open tag.
            let composer = await RenderedMarkup.composer()
            #expect(
                composer.contains("data-submit-on-enter=\"plain\""),
                "a textarea opts in to Enter-to-submit by VALUE; the bare attribute leaves it exempt"
            )
            #expect(
                composer.contains("data-clear-on-submit"),
                "the engine clears the field on the submit event"
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