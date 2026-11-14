import Foundation
import Testing
@testable import ArcWebUI
import ArcAgentCore

// the kanban name editors are the engine's `data-inline-edit` consequence, not a
// client-side editor: the form carries the behavior, the engine's click handler
// enters local edit mode (no round trip), the `type="button"` cancel and Escape
// leave it, and the form's own native submit both exits the mode and rides the
// pane's existing `kanban` submit wire.
//
// two halves have to stay in step, and each one is a separate pin below:
//   1. the emitted markup — the behavior attribute on the form that CONTAINS the
//      field (`el.closest('form')` is what the engine hooks for submit-exit), the
//      full name in the field, and the id field emitted last so
//      `querySelector('input, textarea')` focuses the text field;
//   2. the server wire — the field names `handleKanban`'s submit branch reads are
//      the ones the form emits, and they are the pre-existing names (the hidden
//      form the overlay used to build carried them).
// the overlay half of this contract is the engine's consequence; A8 deleted the
// last source-text pin of the hand-rolled editor (it could only pass against
// deleted code), so the rendered markup above is the proof that it stays gone.
extension ArcWebUITestRoot {
	@Suite("kanban inline edit consequence", .serialized)
	struct InlineEditConsequenceTests {

		private func app(_ configure: (inout AppState.RenderFixture) -> Void = { _ in }) -> AppState {
			var fixture = AppState.RenderFixture()
			fixture.settings.theme = "light"
			configure(&fixture)
			return AppState(renderFixture: fixture)
		}

		/// a repo-relative source file, read beside this test so the suite checks
		/// the tree it is compiled into.
		private func source(_ path: String) throws -> String {
			let root = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()   // ArcAgentWebUITests
				.deletingLastPathComponent()   // Tests
				.deletingLastPathComponent()   // package root
				.appendingPathComponent(path)
			return try String(contentsOf: root, encoding: .utf8)
		}

		/// the first opening tag named `tag` in `html`, attributes and all.
		private static func openingTag(_ tag: String, in html: String) -> String? {
			let open = "<\(tag)"
			guard let start = html.range(of: open) else { return nil }
			guard let end = html.range(of: ">", range: start.upperBound..<html.endIndex) else { return nil }
			return String(html[start.lowerBound..<end.upperBound])
		}

		@Test("a column header is a data-inline-edit form over the kanban wire")
		func columnHeaderCarriesInlineEdit() async {
			let col = KBColumn(id: "col-1", name: "Backlog", color: "#5BB98C")
			let html = await app { $0.kanbanColumns = [col] }.kanbanColumnHTML(col, lane: KBLane(id: "lane-1", name: "General"), isPrimary: true).markup.html

			let form = Self.openingTag("form", in: html)
			#expect(form != nil, "the column header must emit a form")
			// the container IS the form: the engine removes `[data-editing]` from
			// `el.closest('form')` on submit, so a wrapper outside the form would
			// leave the edit mode stuck open.
			#expect(form?.contains("data-inline-edit") == true,
			        "the form must carry the behavior attribute: \(form ?? "—")")
			#expect(form?.contains("data-component-id=\"kanban\"") == true,
			        "the save must ride the existing kanban wire: \(form ?? "—")")
			#expect(form?.contains("data-event=\"submit\"") == true,
			        "a click inside the form must not be dispatched: \(form ?? "—")")

			#expect(html.contains("<span class=\"kb-col-name\""), "the name is the display span")
			#expect(html.contains("name=\"kb-col-name\" type=\"text\" value=\"Backlog\""),
			        "the field is pre-filled with the current name and named for the wire")
			#expect(html.contains("name=\"kb-col-id\" type=\"hidden\" value=\"col-1\""),
			        "the id field rides the same submit")
			#expect(html.contains("type=\"submit\" title=\"Save name\""), "a save control that submits")
			#expect(html.contains("type=\"button\" title=\"Cancel rename\""),
			        "the cancel is a plain button — the engine reads it as the local cancel gesture")
			#expect(!html.contains("kb-rencol-"),
			        "the pencil that opened the hand-rolled editor is gone with it")
		}

		@Test("the id field follows the text field, so edit entry focuses the text")
		func textFieldPrecedesHiddenId() async {
			let col = KBColumn(id: "col-1", name: "Backlog", color: "#5BB98C")
			let html = await app { $0.kanbanColumns = [col] }.kanbanColumnHTML(col, lane: KBLane(id: "lane-1", name: "General"), isPrimary: true).markup.html
			let text = html.range(of: "name=\"kb-col-name\"")
			let hidden = html.range(of: "name=\"kb-col-id\"")
			#expect(text != nil && hidden != nil)
			if let text, let hidden {
				// `el.querySelector('input, textarea')` takes the FIRST match; a
				// hidden field ahead of the text field would make the focus() a
				// no-op and leave the editor untypeable.
				#expect(text.lowerBound < hidden.lowerBound,
				        "the hidden id field must not precede the text field")
			}
		}

		@Test("a card title is the same form, pre-filled with the full title")
		func cardTitleCarriesFullTitle() async {
			let col = KBColumn(id: "col-1", name: "Backlog", color: "#5BB98C")
			// longer than both the 70-char display clamp and the old 40-char seed:
			// seeding the editor from the rendered text committed permanent
			// truncation (UX-21), so the field must carry the stored title.
			let full = String(repeating: "long title ", count: 12).trimmingCharacters(in: .whitespaces)
			let html = await app {
				$0.kanbanColumns = [col]
				$0.kanbanCards = [KBCard(id: "card-1", columnID: "col-1", title: full)]
			}.kanbanColumnHTML(col, lane: KBLane(id: "lane-1", name: "General"), isPrimary: true).markup.html

			#expect(html.contains("<form data-inline-edit") || html.contains(" data-inline-edit"),
			        "the card title carries the same behavior")
			#expect(html.contains("name=\"kb-card-title\" type=\"text\" value=\"\(full)\""),
			        "the field holds the full stored title, not the truncated display text")
			#expect(html.contains("name=\"kb-card-id\" type=\"hidden\" value=\"card-1\""))
			#expect(full.count > 70, "the fixture must exceed the display clamp for this pin to mean anything")
			#expect(html.contains("class=\"kb-card-title\" title=\"Edit title\">"),
			        "the display is still the title element")
			#expect(!html.contains("title=\"Edit title\">\(full)<"),
			        "the display must stay clamped, not print the full title")
			#expect(html.contains("…</div>"), "the display clamp marks itself with an ellipsis")
			#expect(!html.contains("kb-edit-"),
			        "the edit pencil is gone with the hand-rolled editor")
		}

		@Test("the emitted field names are the ones the kanban submit branch reads")
		func wireFieldNamesAreShared() throws {
			let actions = try source("Sources/ArcWebUI/Actions.swift")
			#expect(actions.contains("@Wired(\"kanban\", events: [.click, .submit])"),
			        "the wire the form rides is the pre-existing kanban wire")
			for field in ["kb-col-id", "kb-col-name", "kb-card-id", "kb-card-title"] {
				#expect(actions.contains("event.string(\"\(field)\")"),
				        "handleKanban no longer reads \(field)")
			}
		}
	}
}
