import Testing
import WebUI

@testable import ArcWebUI

// why arc owns the confirmation dialog's focus behaviour when the engine ships
// its own trap — pinned from both sides, in-process, so the justification can
// never quietly rot back into the claim it replaced.
//
// `overlay.js` keeps the dialog's focus, Escape and Tab handling, and the
// comment above that block used to say the engine had no modal focus trap
// (citing a no-webui limitation that does not exist at this pin). the engine at
// `b249bd7` does ship one: `restoreModalFocus` (`webui-engine.js:1465`, called
// at `:394` and `:1412`) plus a `Tab` trap on `.modal-overlay` (`:1483`), so
// that premise was false and must not come back.
//
// what the engine does not do is survive a fragment patch. it holds the opener
// as a raw element reference (`var modalFocus = null` at `:1454`,
// `modalFocus = from` at `:1480`) and later calls `opener.focus()`. the patch
// that opens the dialog also re-renders the chat header, so the trigger the
// user clicked is disconnected and that `focus()` silently no-ops. arc's block
// re-queries instead — `modalReturnFocus = { id, sid }`, resolved by `id` or
// the owning session row's `data-sid` through `rowSidOf` — which is the real
// reason the block exists, and why it is kept deliberately rather than deleted
// as redundant with the engine.
//
// half (a) pins the engine capability the comment now names, so a future
// engine that starts re-querying its own opener makes the comment visibly
// stale instead of silently wrong. half (b) pins the overlay's re-query and
// the absence of the old `STABILITY.md` claim from the shipped bytes.
// both read what the daemon actually serves — `WebUIAssets.engine` and
// `AppShell.Assets.overlay.bytes` as /ui/init.js — never the sources on disk,
// so an embed that stopped tracking its source cannot leave these green.
extension ArcWebUITestRoot {

    @Suite("Modal focus", .serialized)
    struct ModalFocusContractTests {

        /// the engine as the daemon serves it, not the checkout under
        /// `.build/checkouts`.
        private static var engine: String { WebUIAssets.engine }

        /// the bytes the daemon serves as /ui/init.js, not `Assets/overlay.js`.
        private static var overlay: String {
            String(decoding: AppShell.Assets.overlay.bytes, as: UTF8.self)
        }

        @Test("the served engine carries its own modal focus trap")
        func engineCarriesItsOwnTrap() {
            let js = Self.engine
            #expect(
                js.contains("function restoreModalFocus() {"),
                "the engine no longer defines restoreModalFocus — the comment above arc's modal block names it, so re-derive both"
            )
            #expect(
                js.contains("if (e.key !== 'Tab') return;") &&
                    js.contains("var modal = e.target.closest('.modal-overlay');"),
                "the .modal-overlay Tab trap is gone from the engine — arc's block is then the only trap, and the comment has to say so"
            )
            #expect(
                js.contains("modalFocus = from"),
                "the engine no longer captures the modal opener on focusout — the raw-reference premise in arc's comment needs re-derivation"
            )
            #expect(
                js.contains("var opener = modalFocus;") && js.contains("opener.focus()"),
                "the engine no longer restores focus through the captured element — arc's re-query rationale rests on this call"
            )
        }

        @Test("the served overlay re-queries the modal opener and claims no missing engine trap")
        func overlayReQueriesTheOpener() {
            let js = Self.overlay
            #expect(
                js.contains("modalReturnFocus"),
                "arc's modal opener memory is gone — focus return no longer survives a patch-replaced trigger"
            )
            #expect(
                js.contains("rowSidOf"),
                "the sid leg of the modal re-query is gone — a replaced trigger could only be found by id"
            )
            #expect(
                js.contains("data-sid"),
                "the overlay no longer resolves the opener through its session row's data-sid"
            )
            #expect(
                !js.contains("STABILITY.md"),
                "the false premise is back in the served bytes: the engine ships a modal focus trap at this pin, so no STABILITY.md limitation justifies arc's block"
            )
        }
    }
}
