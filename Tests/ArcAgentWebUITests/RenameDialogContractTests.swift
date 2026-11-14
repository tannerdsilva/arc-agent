import Foundation
import Testing
import WebUI

import ArcAgentCore
@testable import ArcWebUI

// why rename is a server dialog now, pinned from both sides in-process so the
// claim cannot rot back into the client editor it replaced.
//
// A16a retires the inline editor (an overlay click handler that swapped the
// row's title button for an `<input>`, then posted a hidden `#rename-form`) for
// ONE server-rendered card: the row menu's "Rename conversation" arms
// `#rename-overlay`, the card's form posts `rename-id` / `rename-name` to the
// `chat-menu` wire, and every focus behaviour is the engine's 2.14.0 contract
// (`autofocus` entry, `data-dismiss` Escape, `data-focus-return` on Cancel).
//
// half (a) pins the emissions on the bytes the server renders — the opener, the
// card, its form, and the return target — and half (b) pins the served
// overlay's silence about rename, because a name reappearing there is the
// duplicate coming back.
//
// `data-full-title` is why the field seeds from `sessionTitle` and not from the
// row text: the row clamps to 40 chars (UX-06) and committing a clamped title
// would bake the truncation in (UX-21).
extension ArcWebUITestRoot {

	@Suite("Rename dialog", .serialized)
	struct RenameDialogContractTests {

		/// the bytes the daemon serves as /ui/init.js, not `Assets/overlay.js`.
		private static var overlay: String {
			String(decoding: AppShell.Assets.overlay.bytes, as: UTF8.self)
		}

		/// the open tag carrying `id`, or nil. the leading space in the pattern
		/// keeps `data-component-id="x"` from answering for `id="x"`.
		static func openTag(_ html: String, id: String) -> String? {
			guard let r = html.range(of: "<[a-z]+[^>]* id=\"\(id)\"[^>]*>",
			                         options: .regularExpression) else { return nil }
			return String(html[r])
		}

		private static func fixture() -> AppState {
			var fixture = AppState.RenderFixture()
			let longTitle = "A conversation whose stored title runs past the row clamp"
			fixture.sessions = [
				Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
				        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: longTitle,
				        messageCount: 2, messages: [Message(role: .user, content: "hi")]),
			]
			fixture.activeSessionID = "sess-a"
			fixture.settings.sessionTitles = ["sess-a": longTitle]
			fixture.renameSessionID = "sess-a"
			return AppState(renderFixture: fixture)
		}

		@Test("the row menu opens a server dialog whose form posts the rename pair")
		func dialogCarriesTheWholeContract() async {
			let app = Self.fixture()
			let encID = enc("sess-a")

			let panel = await app.chatPanel().markup.html
			let opener = Self.openTag(panel, id: "sm-rename-\(encID)")
			#expect(opener != nil, "the row menu lost its Rename entry — the dialog would have no opener")
			#expect(opener?.contains("data-sid=\"sess-a\"") == true,
			        "the Rename entry must still carry the session it renames")

			let html = await app.modalRootHTML().markup.html
			let overlay = Self.openTag(html, id: "rename-overlay")
			#expect(overlay != nil, "no `#rename-overlay` rendered for an armed rename")
			#expect(overlay?.contains("class=\"modal-overlay\"") == true,
			        "the rename card must carry `.modal-overlay`: a native `<dialog open>` renders in flow, so the overlay class is what makes it a modal without JS")

			// the FORM is the card, so the dialog role and its naming ride it —
			// the wrapper is only the overlay the engine's Escape looks for.
			let form = Self.openTag(html, id: "rename-form")
			#expect(form?.contains("role=\"dialog\"") == true, "the card is the dialog — it must say so")
			#expect(form?.contains("aria-modal=\"true\"") == true,
			        "a modal dialog must be announced as one")
			#expect(form?.contains("aria-labelledby=\"rename-title\"") == true,
			        "the dialog must be named by its title")
			#expect(form?.contains("data-component-id=\"chat-menu\"") == true,
			        "the form must route to the `chat-menu` wire — `handleChatMenu`'s submit branch reads `rename-id`/`rename-name` there")

			let field = Self.openTag(html, id: "rename-name")
			#expect(field?.contains("name=\"rename-name\"") == true, "the field must post as `rename-name`")
			#expect(field?.contains("value=\"A conversation whose stored title runs past the row clamp\"") == true,
			        "the field must seed from the FULL stored title — the 40-char row clamp would commit truncation (UX-21)")
			#expect(field?.contains("autofocus") == true,
			        "the field carries `autofocus`: a patched-in dialog has no other entry path at 2.14.0 (F3)")
			#expect(Self.openTag(html, id: "rename-id")?.contains("value=\"sess-a\"") == true,
			        "the hidden `rename-id` must name the session being renamed")

			let cancel = Self.openTag(html, id: "rename-cancel")
			#expect(cancel?.contains("data-dismiss") == true,
			        "Cancel must be the layer's `[data-dismiss]` control — the engine's Escape fires it")
			#expect(cancel?.contains("data-focus-return=\"s-menu-\(encID)\"") == true,
			        "Cancel must return focus to the row's ⋮ (`s-menu-<sid>`): the menu entry that armed the dialog is gone with the menu the same click closed")
			#expect(cancel?.contains("type=\"button\"") == true,
			        "Cancel must not submit the form it sits in")

			#expect(Self.openTag(html, id: "rename-save")?.contains("type=\"submit\"") == true,
			        "the confirm control is the form's submit — one round trip, no client commit")
		}

		@Test("the served overlay keeps no rename editor")
		func overlayCarriesNoRenameCode() {
			let js = Self.overlay
			for name in ["submitRename", "rename-input", "sm-rename-"] {
				#expect(!js.contains(name),
				        "the served overlay still mentions `\(name)`: the inline editor is back, and the dialog is no longer the only rename path")
			}
		}
	}
}
