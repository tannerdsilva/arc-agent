import Foundation
import Testing
import WebUI

import ArcAgentCore
@testable import ArcWebUI

// A16d: the post-patch seam is GONE. Its three consumers were each blocked on
// a framework behaviour, and 3.1.0 shipped all three:
//
//  1. the A15 draft-store guard — `onDocSubmit` now drops
//     `webui-draft:<identity>` for a cleared `[data-clear-on-submit]
//     [data-draft-id]` control, so the post-submit refill cannot happen;
//  2. the new-chat caret (UX-45) — `FocusOnAppear()` on the composer textarea
//     covers "an element that appears and nothing holds focus";
//  3. `[data-focus-after-patch]` — the same behaviour, now emitted by the
//     form fragments that ask for the caret.
//
// The seam's whole vocabulary (`enhanceAll`, `bootOnReady`, `on.ready`,
// `WebUIEngine.on.afterPatch`, `registerSeam`) must not come back: a new client
// consequence is either a framework behaviour or a defect report, never a
// second registration. The remaining tests pin the T26 ids the A16c slice added.
extension ArcWebUITestRoot {

	@Suite("Overlay seam", .serialized)
	struct OverlaySeamContractTests {

		private static var overlay: String {
			String(decoding: AppShell.Assets.overlay.bytes, as: UTF8.self)
		}

		static func openTag(_ html: String, id: String) -> String? {
			guard let r = html.range(of: "<[a-z]+[^>]* id=\"\(id)\"[^>]*>",
			                         options: .regularExpression) else { return nil }
			return String(html[r])
		}

		@Test("the seam is dead: no afterPatch registration and no seam consumer survives")
		func seamIsDead() {
			let js = Self.overlay
			for retired in ["WebUIEngine.on.afterPatch", "on.ready", "enhanceAll",
			                "enhancePatched", "bootOverlay", "bootOnReady",
			                "registerSeam", "DOMContentLoaded",
			                "clearRestoredComposer", "submittedComposerText",
			                "focusComposerWanted", "[data-focus-after-patch]"] {
				#expect(!js.contains(retired),
				        "the dead seam's `\(retired)` is back — 3.1.0 owns every consumer it had")
			}
			// the three survivors the engine still has no consequence for, named
			// so a fourth cannot ride in unnoticed.
			for survivor in ["ws-panel", "outline-panel", ".cat-swatch", "ws-closing"] {
				#expect(js.contains(survivor),
				        "a classified survivor `\(survivor)` is gone — delete it deliberately, not by drift")
			}
			// the blank canvas is the engine's skip target now, so its old
			// client hook must not survive.
			#expect(!js.contains("focus-composer"),
			        "the blank canvas' client focus hook is back; `data-skip-to` owns that consequence")
		}

		@Test("the new-chat caret is a one-render FocusInto on the composer root")
		func composerFocusIsAOneRenderLatch() async {
			let app = AppState(renderFixture: .init())
			let unarmed = await app.composerHTML().markup.html
			#expect(!unarmed.contains("data-focus-into"),
			        "an unarmed composer render must not move focus — a durable statement would yank the caret on every patch")
			await app.armComposerFocus()
			let armed = await app.composerHTML().markup.html
			let root = Self.openTag(armed, id: "composer-wrap")
			#expect(root?.contains("data-focus-into=\"composer-input\"") == true,
			        "`newChat` arms the latch, and the render states `data-focus-into` on the composer root — FocusOnAppear cannot take focus from the surviving `+`")
			let later = await app.composerHTML().markup.html
			#expect(!later.contains("data-focus-into"),
			        "the latch is ONE render: a later render must not steal the caret")
		}

		@Test("the workspace ⋮ menu is one server render of data-open, then closed")
		func wsMenuIsAOneRenderLatch() async {
			let app = AppState(renderFixture: .init())
			await app.armWsMenu()
			let armed = await app.workspacePanelHTML().markup.html
			let open = Self.openTag(armed, id: "ws-menu")
			#expect(open?.contains("data-open=") == true,
			        "the armed render must state `data-open` — the ⋮ has no client toggle any more")
			#expect(open?.contains("data-dismiss") == true,
			        "the menu must arm the engine's dismiss stack in the same contribution, or Escape/outside-click cannot close it")
			let later = await app.workspacePanelHTML().markup.html
			#expect(Self.openTag(later, id: "ws-menu")?.contains("data-open") == false,
			        "the latch is ONE render: a later render that re-asserted data-open would reopen a menu the engine dismissed")
		}

		@Test("the kanban rename field carries a per-row id (T26)")
		func kanbanFieldIsKeyed() async {
			var fixture = AppState.RenderFixture()
			fixture.kanbanColumns = [
				KBColumn(id: "col-1", name: "Backlog", color: "#5BB98C"),
				KBColumn(id: "col-2", name: "Done", color: "#2F9EB7"),
			]
			let html = await AppState(renderFixture: fixture).kanbanMain().markup.html
			let first = Self.openTag(html, id: "kb-col-name-\(enc("col-1"))")
			let second = Self.openTag(html, id: "kb-col-name-\(enc("col-2"))")
			#expect(first != nil && second != nil,
			        "each column's rename field needs its own id: the engine's input-state memo keys on `formScope|id-or-name`, and one shared key means one value (and one focus target) for every column")
			#expect(first?.contains("name=\"kb-col-name\"") == true,
			        "the id must not replace the wire key: `handleKanban` reads `kb-col-name`")
		}

		@Test("the attachment chip's ✕ is keyed by path, not index (T26)")
		func attachmentChipIsKeyedByPath() async {
			var fixture = AppState.RenderFixture()
			fixture.activeSessionID = "sess-a"
			fixture.sessions = [Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
			                            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Chat",
			                            messageCount: 1, messages: [Message(role: .user, content: "hi")])]
			let app = AppState(renderFixture: fixture)
			await app.addAttachment("notes/a.md")
			await app.addAttachment("notes/b.md")
			let html = await app.composerHTML().markup.html
			#expect(Self.openTag(html, id: "att-del-\(enc("notes/a.md"))") != nil,
			        "the ✕ must be keyed by the attachment's path — an index id lands on a DIFFERENT chip once an earlier one is removed")
			#expect(Self.openTag(html, id: "att-del-\(enc("notes/b.md"))") != nil,
			        "the second chip must have its own id")
			#expect(!html.contains("id=\"att-del-0\""),
			        "an index-keyed ✕ is back — focus and the removal itself follow the wrong chip")
		}
	}
}
