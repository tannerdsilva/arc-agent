/// `data-no-restore` — the attribute `ArcSwitch` emits on every toggle.
///
/// the engine's fragment patch saves a form control's `value`/`checked` before
/// the swap and restores it after, which is right for a field the user is typing
/// in and wrong for a toggle the server re-renders authoritatively: the saved
/// value wins and the switch snaps back to the stale one. `data-no-restore` is
/// how a node refuses that restore, so the attribute only means anything if the
/// engine the daemon actually serves implements it.
///
/// this is a pin contract, not a behaviour test: a Swift test cannot execute the
/// engine, so it asserts the two halves that must both be true — the served
/// engine bytes carry the opt-out predicate, and arc's switch emits the
/// attribute. the behavioural proof is the framework's own
/// `designer/fragment-restore-probe.mjs` case 3, which drives the real
/// saveInputState → replace → restoreInputState path in a browser.
///
/// red at the `403b23b` pin (that engine has zero references to the attribute),
/// green after the bump to `b249bd7` — which is the whole point of Task 0.1.
@testable import ArcWebUI
import Testing
import WebUI

extension ArcWebUITestRoot {
	@Suite("Switch restore", .serialized)
	struct SwitchRestoreTests {

		@Test("the served engine bytes honour data-no-restore")
		func engineHonoursNoRestore() {
			// `WebUIAssets.engine` is the string `WebUIServer` serves at
			// /ui/webui-engine.js — the bytes a browser receives, not a file on disk,
			// so this cannot pass against a checkout the daemon does not ship.
			let engine = WebUIAssets.engine
			#expect(
				engine.contains("data-no-restore"),
				"""
				the served engine has no reference to data-no-restore: every ArcSwitch \
				on the page is still subject to the stale-checked restore the attribute \
				exists to prevent. bump the no-webui pin (Task 0.1).
				"""
			)
			#expect(
				engine.contains("hasAttribute('data-no-restore')"),
				"""
				the served engine mentions data-no-restore but not as an attribute \
				predicate — read the engine's saveInputState before trusting the name
				"""
			)
		}

		@Test("an ArcSwitch opts out of fragment restore in both states")
		func switchesIgnoreFragmentRestore() {
			let on = ArcSwitch(id: "sk-alpha", on: true).markup.html
			#expect(
				on.contains("data-no-restore=\"\""),
				"an on switch must emit data-no-restore — without it a patch re-applies the stale checked"
			)
			#expect(
				on.contains("checked=\"\""),
				"an on switch must still emit checked — the opt-out suppresses restore, not the server value"
			)

			let off = ArcSwitch(id: "sk-beta", on: false).markup.html
			#expect(
				off.contains("data-no-restore=\"\""),
				"an off switch must emit data-no-restore too"
			)
			#expect(
				!off.contains("checked=\"\""),
				"an off switch must not emit checked"
			)
		}
	}
}
