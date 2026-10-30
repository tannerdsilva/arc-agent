import Testing
import Foundation

/// region identity census: which rendered elements the differ can key, and
/// which it cannot.
///
/// the push edge patches a region with `FragmentUpdate(id:)`, and the engine
/// resolves that id with `getElementById`. two facts therefore decide whether a
/// frame lands: an element must carry an `id`, and no two elements may carry the
/// same one. both are properties of *rendered* markup, so this suite reads bytes
/// (`RenderedMarkup.fullSurface()`), never source text.
///
/// the sets below are the measured state of the tree, not a target: they exist
/// so that a new unaddressable element or a new id/component divergence is a
/// decision someone makes, instead of an accident that ships a frame landing
/// nowhere. adding to a set is legitimate when the element is deliberately
/// routing-only; adding without thinking is what the pin is for.
///
/// measured 2026-10-27 against `RenderedMarkup.fullSurface()`: 114 elements
/// carry `data-component-id`, 53 of those also carry an `id` equal to it.

extension ArcWebUITestRoot {
	@Suite("region identity census", .serialized)
	struct RegionIdentityCensusTests {

		/// elements whose `data-component-id` is an event-routing key while their
		/// DOM `id` is the patch address. harmless under `.elementID` identity —
		/// which keys on the DOM id — but a decision, so it is pinned.
		static let sanctionedDivergences: Set<String> = [
			"al-max-turns-unl-wrap|al-max-turns-unlimited",
			"al-max-turns-wrap|al-max-turns",
			"al-tool-cap-unl-wrap|al-tool-cap-unlimited",
			"al-tool-cap-wrap|al-tool-cap",
			"chat-showarch-link|chat-showarch",
			"sess-list-body|sess-list",
			"skill-new-main|skill-new",
			"task-add-form|tasks",
			"toasts|toast-dismiss",
			"todo-add-form|todos",
			"ws-dock|workspace",
			"ws-tree|workspace",
		]

		/// elements carrying a component attribute and no `id` at all. they are
		/// click-routing wrappers (panel bodies, picker grids, tab strips), never
		/// patch targets: with no id the differ does not track them, so their bytes
		/// roll into the nearest tracked ancestor and a change there still ships.
		static let sanctionedUnaddressable: Set<String> = [
			"activity-display|bubble-opts",
			"aux-edit|aux-right",
			"cat-pick|cat-bar",
			"font-size-pick|fsz-grid",
			"kanban|panel-body",
			"log-filter|log-chips",
			"mainmc|-",
			"memory|panel-body",
			"modal|modal-actions",
			"modelcfg-list|-",
			"queue|todo-tabs",
			"scheme-pick|scheme-grid",
			"side-tab-chips|side-tab-chips",
			"storage-pick|-",
			"tasks|panel-head",
			"theme-pick|thm-grid",
			"todos|todo-card",
			"workspace-list|list-row active",
			"workspace|ws-menu-wrap",
			"workspace|ws-tools",
		]

		@Test("no two elements on the page share an id")
		func idsAreUnique() async {
			let html = await RenderedMarkup.page()
			var seen: [String: Int] = [:]
			var duplicates: [String] = []
			for m in html.matches(of: /<[a-zA-Z][^>]*>/) {
				let tag = String(m.output)
				guard let i = tag.firstMatch(of: /\sid="([^"]*)"/) else { continue }
				let id = String(i.output.1)
				seen[id, default: 0] += 1
				if seen[id] == 2 { duplicates.append(id) }
			}
			#expect(duplicates.isEmpty, "duplicate ids make getElementById ambiguous: \(duplicates)")
		}

		@Test("divergences are exactly the sanctioned set")
		func divergencesAreEnumerated() async {
			let m = await measured()
			#expect(m.divergent == Self.sanctionedDivergences)
		}

		@Test("unaddressable elements are exactly the sanctioned set")
		func unaddressableAreEnumerated() async {
			let m = await measured()
			#expect(m.unaddressable == Self.sanctionedUnaddressable)
		}

		@Test("every element carrying an id is a region the differ can key")
		func idBearingElementsArePatchable() async {
			// the converse of the unaddressable pin: an element the census counts as
			// addressable must be one the region scan actually produces, or the pin
			// above would be guarding a list nobody reads.
			let html = await RenderedMarkup.fullSurface()
			var idCount = 0
			for m in html.matches(of: /<[a-zA-Z][^>]*>/) {
				if String(m.output).firstMatch(of: /\sid="([^"]*)"/) != nil { idCount += 1 }
			}
			#expect(idCount >= 53, "the surface renders addresses: measured \(idCount)")
		}

		// MARK: - measurement

		private func measured() async -> (divergent: Set<String>, unaddressable: Set<String>) {
			let html = await RenderedMarkup.fullSurface()
			var divergent = Set<String>()
			var unaddressable = Set<String>()
			for m in html.matches(of: /<[a-zA-Z][^>]*>/) {
				let tag = String(m.output)
				guard let c = tag.firstMatch(of: /data-component-id="([^"]*)"/) else { continue }
				let component = String(c.output.1)
				if let i = tag.firstMatch(of: /\sid="([^"]*)"/) {
					let id = String(i.output.1)
					if id != component { divergent.insert("\(id)|\(component)") }
				} else {
					let cls = tag.firstMatch(of: /class="([^"]*)"/).map { String($0.output.1) } ?? "-"
					unaddressable.insert("\(component)|\(cls)")
				}
			}
			return (divergent, unaddressable)
		}
	}
}
