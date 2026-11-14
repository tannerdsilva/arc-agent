import Foundation
import Testing
import WebUI

import ArcAgentCore
@testable import ArcWebUI

// A16c: the post-patch seam is down to the three consumers a framework
// behaviour owns, and every one of them is named here so a fourth cannot ride in
// unnoticed.
//
// The retired seam: `bootOverlay` (a DOMContentLoaded boot), `bootOnReady` (a
// helper with no callers since the workspace boot went), `enhanceAll` (a pass
// whose only job was the staged copy marker) and the `on.ready` registration.
// What survives is ONE `afterPatch` registration and the three consumers
// blocked on A16d:
//
//  1. `clearRestoredComposer` — no-webui 2.17.0 clears the composer CONTROL on
//     submit but not its `webui-draft:<identity>` store, so the next replacing
//     patch refills the field with the text that was just sent.
//  2. the new-chat caret (UX-45) — `autofocus` is once per document (A12/F3).
//  3. `[data-focus-after-patch]` — the same missing focus-on-appearance
//     behaviour, for a form fragment that asks for the caret when it lands.
//
// The second half pins the T26 ids the slice added: the engine's input-state
// memo keys on `formScope|id-or-name`, so a control without an id either
// collides with its siblings (the kanban rename field, one key for every
// column) or shifts it (the attachment ✕, keyed by index).
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

		@Test("the seam is one afterPatch registration and exactly three consumers")
		func seamIsThreeConsumers() {
			let js = Self.overlay
			#expect(js.contains("WebUIEngine.on.afterPatch(enhancePatched)"),
			        "the three consumers below have no registration — nothing runs after a patch")
			#expect(js.components(separatedBy: "WebUIEngine.on.afterPatch").count - 1 == 1,
			        "more than one afterPatch registration is a second seam")
			for retired in ["on.ready", "enhanceAll", "bootOverlay", "bootOnReady"] {
				#expect(!js.contains(retired),
				        "the served overlay still mentions `\(retired)`: the retired seam is back")
			}
			#expect(js.contains("function registerSeam()") && js.contains("document.addEventListener('DOMContentLoaded', registerSeam)"),
			        "the hook must still defer to the engine's script: /ui/init.js precedes /ui/webui-engine.js in the head, so `WebUIEngine` does not exist while this file parses — a parse-time registration silently leaves the seam dead")
			for consumer in ["function clearRestoredComposer()",
			                 "focusComposerWanted",
			                 "[data-focus-after-patch]"] {
				#expect(js.contains(consumer),
				        "the A16d-blocked consumer `\(consumer)` is gone — either A16d shipped the behaviour (then delete this row) or the guard was lost silently")
			}
			// the blank canvas is the engine's skip target now, so its old
			// client hook must not survive.
			#expect(!js.contains("focus-composer"),
			        "the blank canvas' client focus hook is back; `data-skip-to` owns that consequence")
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
