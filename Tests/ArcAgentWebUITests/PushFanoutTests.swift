import Testing
import WebUICore
import WebUIState

@testable import ArcWebUI

/// two connected pages, one baseline.
///
/// the push edge keeps ONE `PageDiffer` for the process, so a tab that opens
/// later joins the same baseline as the tab that was already there. that is a
/// deliberate limitation (a per-session differ would be a larger change), and
/// the thing that makes it safe is that a push fans out as a single broadcast:
/// every socket receives the same bytes, so no client can be a frame ahead or
/// behind another. these two assertions pin that shape — if the edge ever
/// diffed per client, the first one fails.
@Suite("push fan-out")
struct PushFanoutTests {
	/// the page the door renders, mutable between pushes.
	private actor PageBox {
		private(set) var markup: String
		init(_ markup: String) { self.markup = markup }
		func set(_ next: String) { markup = next }
	}

	private func page(panel: String) -> String {
		#"<div id="app" data-component-id="app"><div id="panel" data-component-id="panel">\#(panel)</div></div>"#
	}

	private func makeEdge(
		_ box: PageBox, _ recorder: PushRecorder
	) -> PushEdge {
		PushEdge(
			differ: PageDiffer(policy: PushEdge.livePolicy),
			render: { await box.markup },
			broadcast: recorder.push
		)
	}

	@Test("one push is one broadcast, so every connected page receives identical bytes")
	func oneBroadcastPerPush() async {
		let box = PageBox(page(panel: "a"))
		let recorder = PushRecorder()
		let edge = makeEdge(box, recorder)
		edge.seed(await box.markup)

		await box.set(page(panel: "b"))
		await edge.push([FragmentUpdate(id: "panel", html: "")])

		let log = await recorder.log
		#expect(log.count == 1, "a per-client diff would put more than one batch on the wire for one push")
		#expect(log.first?.ids == ["panel"])
		#expect(
			log.first?.updates.allSatisfy { $0.transition == false } ?? false,
			"the policy's transition flag is uniform — no client gets a different update")
	}

	@Test("a tab that joins late converges on the next push, and a repeat push is silent")
	func lateJoinConvergesWithoutDuplicates() async {
		let box = PageBox(page(panel: "a"))
		let recorder = PushRecorder()
		let edge = makeEdge(box, recorder)
		edge.seed(await box.markup)

		await box.set(page(panel: "b"))
		await edge.push([FragmentUpdate(id: "panel", html: "")])
		// a second structural push with nothing changed must not re-send: the
		// baseline is shared, so both tabs stay consistent without a duplicate.
		await edge.push([FragmentUpdate(id: "panel", html: "")])

		let log = await recorder.log
		#expect(log.count == 1, "an unchanged page broadcasts nothing, however many clients are attached")
	}
}
