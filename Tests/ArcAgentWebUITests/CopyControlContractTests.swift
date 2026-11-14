import Foundation
import Testing
import WebUI

import ArcAgentCore
@testable import ArcWebUI

// A16b (F5): every copy surface is the ENGINE's `[data-copy]`, and the value it
// carries is server-rendered text.
//
// The retired machinery: `flashToast` (a client toast builder beside the
// server's `#toasts`), `copyFromServerMarker` (a post-patch pass that consumed a
// staged `<span id="pending-copy" data-copy-url>` marker because the resolved
// link only existed after a round trip), and the two per-surface click handlers
// (the workspace preview's `innerText` read and the work-log round's
// `.wl-detail` read). `webui-engine-ext.js` binds `[data-copy]`, writes the
// clipboard, and paints one `[data-webui-toast]` pill — so each of these
// assertions is about the VALUE the server hands that binder, which is the only
// half of the contract arc still owns.
extension ArcWebUITestRoot {

	@Suite("Copy controls", .serialized)
	struct CopyControlContractTests {

		private static var overlay: String {
			String(decoding: AppShell.Assets.overlay.bytes, as: UTF8.self)
		}

		static func openTag(_ html: String, id: String) -> String? {
			guard let r = html.range(of: "<[a-z]+[^>]* id=\"\(id)\"[^>]*>",
			                         options: .regularExpression) else { return nil }
			return String(html[r])
		}

		private static func fixture(origin: String) -> AppState {
			var fixture = AppState.RenderFixture()
			fixture.activeSessionID = "sess-a"
			fixture.publicOrigin = origin
			fixture.sessions = [
				Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
				        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Chat",
				        messageCount: 2, messages: [Message(role: .user, content: "hi")]),
			]
			return AppState(renderFixture: fixture)
		}

		@Test("the row menu's copy entry carries the absolute share link")
		func conversationLinkIsAnAbsoluteCopyValue() async {
			let encID = enc("sess-a")

			let absolute = await Self.fixture(origin: "http://127.0.0.1:8890").chatPanel().markup.html
			let entry = Self.openTag(absolute, id: "sm-copy-\(encID)")
			#expect(entry != nil, "the row menu lost its copy entry")
			#expect(entry?.contains("data-copy=\"http://127.0.0.1:8890/?s=\(encID)\"") == true,
			        "the copy entry must carry the WHOLE share url: the engine copies the attribute's text verbatim, so a bare `?s=` puts an unpasteable fragment on the clipboard")

			// a render with no origin (a fixture, or a host that never set one)
			// degrades to the relative form rather than inventing a host.
			let relative = await Self.fixture(origin: "").chatPanel().markup.html
			#expect(Self.openTag(relative, id: "sm-copy-\(encID)")?.contains("data-copy=\"?s=\(encID)\"") == true,
			        "with no public origin the value must stay relative — never a guessed host")
		}

		@Test("a work-log round carries its activity as a plain-text digest")
		func worklogRoundCarriesItsDigest() async {
			let t0 = Date(timeIntervalSince1970: 1_700_000_000)
			let call = ToolCall(id: "call_1",
			                    function: ToolCallFunction(name: "read_file",
			                                               arguments: "{\"path\":\"README.md\"}"))
			let round = [
				Message(role: .assistant, content: "checking the file", toolCalls: [call], createdAt: t0),
				Message(role: .tool, content: "the contents", toolCallID: "call_1", createdAt: t0),
				Message(role: .assistant, content: "done", createdAt: t0),
			]
			let app = Self.fixture(origin: "")
			let html = await app.turnBlockHTML(round, mode: "compact_worklog", turnIndex: 0)?.markup.html ?? ""
			#expect(html.contains("tw-copy"), "the round's copy control did not render")
			#expect(html.contains("data-copy=\"checking the file"),
			        "the digest must start with the round's own text — the old `innerText` read copied nothing for a COLLAPSED round, which is the state the control ships in")
			#expect(html.contains("read_file path: README.md"),
			        "each call contributes its name and one-line argument summary")
		}

		@Test("the preview's copy carries the file's server-rendered text")
		func previewCarriesTheFileText() async {
			var fixture = AppState.RenderFixture()
			fixture.workspaceOpen = true
			fixture.previewPath = "notes.txt"
			fixture.previewContent = "line one\nline \"quoted\" two"
			let app = AppState(renderFixture: fixture)
			let html = await app.workspaceBodyHTML().markup.html
			let copy = Self.openTag(html, id: "ws-preview-copy")
			#expect(copy != nil, "the preview lost its copy control")
			#expect(copy?.contains("data-copy=\"line one") == true,
			        "the preview copy must carry the file's text (the attribute emitter escapes it)")
			#expect(copy?.contains("&quot;quoted&quot;") == true,
			        "quotes must ride the attribute escaped, so the clipboard gets the raw character back")

			// no content, no control: a copy button that cannot copy is worse
			// than an absent one, and the engine's toast reports success only.
			var empty = AppState.RenderFixture()
			empty.workspaceOpen = true
			empty.previewPath = "binary.bin"
			empty.previewContent = nil
			let noContent = await AppState(renderFixture: empty).workspaceBodyHTML().markup.html
			#expect(Self.openTag(noContent, id: "ws-preview-copy") == nil,
			        "an unreadable preview must render no copy control")
		}

		@Test("the toasts fragment keeps no staged copy marker")
		func toastsCarryNoMarker() async {
			var fixture = AppState.RenderFixture()
			fixture.toasts = [Toast(id: 1, text: "Conversation deleted", kind: "info")]
			let html = await AppState(renderFixture: fixture).toastsHTML().markup.html
			#expect(!html.contains("pending-copy"),
			        "the staged marker is gone with its consumer (A16b) — a second consumer would be a second clipboard owner")

			let js = Self.overlay
			for name in ["flashToast", "copyFromServerMarker", "pending-copy", "#ws-preview-copy", "'.tw-copy'"] {
				#expect(!js.contains(name),
				        "the served overlay still mentions `\(name)`: the copy surface is the engine's again")
			}
		}
	}
}
