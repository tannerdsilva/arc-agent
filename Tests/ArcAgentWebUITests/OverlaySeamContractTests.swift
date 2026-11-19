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

		/// the client asset as the daemon serves it, or `""` once A17 deletes the
		/// file. Reading through the source path (not `AppShell.Assets`) keeps
		/// this suite honest across the deletion: every pin below is an ABSENCE,
		/// and an absent file is the strongest form of it.
		private static var overlay: String {
			(try? String(contentsOfFile: "Sources/ArcWebUI/Assets/overlay.js", encoding: .utf8)) ?? ""
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
			// A17: the file held three classified survivors and NOTHING else. All
			// three are the engine's or the sheet's now — the panels are
			// `data-open` layers, the palette is a native radio group and the exit
			// visual is a transition — so no client code may remain at all.
			for retired in ["addEventListener", "querySelector", "classList", "document."] {
				#expect(!js.contains(retired),
				        "`\(retired)` in the client asset means a client consequence came back; A17 deleted the last one")
			}
			// the blank canvas is the engine's skip target now, so its old
			// client hook must not survive.
			#expect(!js.contains("focus-composer"),
			        "the blank canvas' client focus hook is back; `data-skip-to` owns that consequence")
		}

		@Test("the last three survivors are markup, an attribute pair and a transition")
		func survivorsAreTheEngines() {
			// 1. the two panels: `data-open` (serial-valued) + `data-dismiss`, so
			//    the dismiss stack owns Escape and the click-away, LIFO with every
			//    other layer.
			#expect(Self.views.contains(".dismissibleOpen(panelOpen)"),
			        "the workspace panel must arm itself as a layer, not carry a `.hidden` class")
			#expect(Self.views.contains(".dismissibleOpen(outlineOpen ? outlineSerial : nil)"),
			        "the outline must arm itself as a layer")
			// 2. the palette: a native radio group named for the field the server
			//    already reads, so `:checked` is the selection and no hidden mirror
			//    field exists.
			#expect(Self.views.contains("paletteRadios(\"cat-color-input\")"),
			        "the category form's colour field is the radio group's NAME")
			#expect(Self.views.contains("paletteRadios(\"kb-addcol-color\")"),
			        "the kanban form's colour field is the radio group's NAME")
			#expect(Self.views.contains("Input(name: field, type: .radio, value: c)"),
			        "the swatch itself is an `<input type=radio>`")
			// 3. the exit visual: a transition keyed on the layer attribute, with
			//    no `.ws-closing` class and no capture-phase click listener.
			#expect(Self.sheet.contains(".ws-panel[data-open] {"),
			        "the panel's open state is the sheet's, keyed on `data-open`")
			#expect(Self.sheet.contains("transition-property: width, flex-basis, opacity, transform, visibility;"),
			        "one transition list drives the enter AND the exit while the node stays mounted — `.ws-closing` is gone")
			#expect(!Self.sheet.contains(".ws-panel.ws-closing {"),
			        "the client-stamped closing class must be gone")
			#expect(!Self.sheet.contains(".ws-panel.ws-enter"),
			        "the one-shot enter class must be gone — `@starting-style` owns the enter")
			#expect(!Self.sheet.contains(".ws-panel.hidden"),
			        "the panel's visibility is the layer attribute, never a class")
		}

		private static var views: String {
			(try? String(contentsOfFile: "Sources/ArcWebUI/Views.swift", encoding: .utf8)) ?? ""
		}

		private static var sheet: String {
			(try? String(contentsOfFile: "Sources/ArcTheme/ChromeSheet.swift", encoding: .utf8)) ?? ""
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
			// the agent page replaced the legacy board: the per-column editor is
			// `kba-col-edit-<column id>` — the FORM id scopes the input-state
			// memo (`formScope|id-or-name`), so the shared `kba-col-edit-name`
			// field name stays the wire key while every column keeps its own
			// value and focus target.
			var d = KanbanAgent.BoardDocument(name: "T26")
			d.columns = [
				.init(id: "col-1", name: "Backlog", kind: .agentWork),
				.init(id: "col-2", name: "Done", kind: .terminal),
			]
			var f = AppState.RenderFixture()
			f.kanbanAgentDoc = d
			// one popover at a time: open each column's editor in turn
			let app1 = AppState(renderFixture: f)
			await app1.kbSetPopover("kba-col-\(enc("col-1"))")
			let html1 = await app1.kanbanAgentPage().markup.html
			let app2 = AppState(renderFixture: f)
			await app2.kbSetPopover("kba-col-\(enc("col-2"))")
			let html2 = await app2.kanbanAgentPage().markup.html
			let first = Self.openTag(html1, id: "kba-col-edit-\(enc("col-1"))")
			let second = Self.openTag(html2, id: "kba-col-edit-\(enc("col-2"))")
			#expect(first != nil && second != nil,
			        "each column's rename form needs its own id: the engine's input-state memo keys on `formScope|id-or-name`, and one shared key means one value (and one focus target) for every column")
			#expect(html1.contains("kba-col-edit-name"),
			        "the form scope must not replace the wire key: the rename submit reads `kba-col-edit-name`")
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
