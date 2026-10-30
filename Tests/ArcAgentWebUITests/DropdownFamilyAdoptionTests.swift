import Foundation
import Testing

import ArcAgentCore
import ArcTheme
import WebUI
import WebUIDesignSystem
@testable import ArcWebUI

// ADOPT B2.2 — the dropdown family renders through `WebUIDropdown`.
//
// the caller-trigger initializer emits the trigger **verbatim**, so the
// `ArcButton` arc already had stays the click boundary: same `id`, same
// `data-component-id`, same handler. the one trap in that initializer is that
// `id:`/`onSelect:` are register-only — passing them on top of a button that
// registered its own handler would register a second handler for the same id.
// every assertion below reads rendered bytes, not source spellings.

extension ArcWebUITestRoot {
	@Suite("dropdown family adoption", .serialized)
	struct DropdownFamilyAdoptionTests {

		// MARK: - the controls that render through the component

		/// trigger id → the popover's dispatch id (the `@Wired` id the panel wire
		/// answers to). these are the settings-surface pickers: each one's panel
		/// opens into a scrolling column, so the component's downward panel is
		/// reachable. the four composer selectors are deliberately absent — see
		/// `composerSelectorsStayOnTheArcPanel`.
		private static let converted = [
			("mainmc-toggle", "mainmc"),
			("storage-pick-toggle", "storage-pick"),
			("pcs-toggle", "pcs"),
		]

		/// the four composer selectors still render arc's own panel. they open
		/// upward because the composer is the bottom row of `#main`, whose
		/// `overflow: hidden` clips anything below it — the component only opens
		/// downward. converting one of these is a placement decision, not a
		/// refactor: see the b2.2 re-run report.
		private static let composerSelectors = [
			("cb-ws-toggle", "ws-pick"),
			("cb-profile-toggle", "profile-pick"),
			("cb-model-toggle", "model-pick"),
			("cb-think-toggle", "think-pick"),
		]

		private static func viewsSource() throws -> String {
			let url = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()   // ArcAgentWebUITests
				.deletingLastPathComponent()   // Tests
				.deletingLastPathComponent()   // repo root
				.appendingPathComponent("Sources/ArcWebUI/Views.swift")
			return try String(contentsOf: url, encoding: .utf8)
		}

		/// the fixture the pages below are rendered from: one workspace, one
		/// profile, two model configurations — enough that every converted
		/// dropdown renders rows rather than an empty state.
		private static func fixture() -> AppState.RenderFixture {
			var fixture = AppState.RenderFixture()
			fixture.activeSessionID = "sess-a"
			fixture.sessions = [Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
			                            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
			                            title: "Chat", messageCount: 1,
			                            messages: [Message(role: .user, content: "hi")])]
			fixture.settings.workspaces = [WorkspaceEntry(name: "main", path: "/tmp/main")]
			fixture.settings.modelConfigs = [
				ModelConfigPreset(name: "primary", model: "gpt-4o", provider: "openai", baseURL: ""),
				ModelConfigPreset(name: "local", model: "llama-3", provider: "ollama",
				                  baseURL: "http://localhost:11434"),
			]
			fixture.settings.activeConfig = "primary"
			fixture.skills = [
				Skill(name: "alpha", description: "first skill", content: "alpha",
				      path: URL(fileURLWithPath: "/tmp/alpha/SKILL.md")),
				Skill(name: "beta", description: "second skill", content: "beta",
				      path: URL(fileURLWithPath: "/tmp/beta/SKILL.md")),
			]
			return fixture
		}

		/// every page that hosts a dropdown, rendered from one fixture.
		private static func pages() async -> [(name: String, markup: String)] {
			let settings = AppState(renderFixture: fixture())
			let storage = AppState(renderFixture: fixture())
			let profile = AppState(renderFixture: fixture())
			let composer = AppState(renderFixture: fixture())
			return [
				("settings-main", await settings.settingsMain().markup.html),
				("storage", await storage.storageSettingsHTML().markup.html),
				("profile-context-skills", await profile.profileContextSkillsHTML().markup.html),
				("composer", await composer.composerHTML().markup.html),
			]
		}

		// MARK: - markup readers

		/// the value of one attribute in a tag or tag fragment, or nil. the leading
		/// space keeps `data-sid="…"` from answering for `id="…"`.
		static func attribute(_ name: String, in tag: String) -> String? {
			let needle = " \(name)=\""
			guard let found = tag.range(of: needle) else { return nil }
			let rest = tag[found.upperBound...]
			guard let close = rest.firstIndex(of: "\"") else { return nil }
			return String(rest[..<close])
		}

		/// every `<button …>` / `<div …>` open tag in the markup, verbatim.
		static func openTags(in markup: String) -> [String] {
			var out: [String] = []
			var i = markup.startIndex
			while let lt = markup[i...].firstIndex(of: "<") {
				guard let gt = markup[lt...].firstIndex(of: ">") else { break }
				let tag = String(markup[lt...gt])
				if !tag.hasPrefix("</") && !tag.hasPrefix("<!") { out.append(tag) }
				i = markup.index(after: gt)
			}
			return out
		}

		/// the subtree rooted at the `<div class="…dd…">` that contains `needle`,
		/// by div-depth matching. returns "" when the needle is not found.
		static func divSubtree(in markup: String, containing needle: String) -> String {
			guard let hit = markup.range(of: needle) else { return "" }
			guard let open = markup[..<hit.lowerBound].range(of: "<div", options: .backwards) else { return "" }
			var depth = 0
			var i = open.lowerBound
			while i < markup.endIndex {
				let nextOpen = markup.range(of: "<div", range: i..<markup.endIndex)
				let nextClose = markup.range(of: "</div>", range: i..<markup.endIndex)
				guard let close = nextClose else { return "" }
				if let nextOpen, nextOpen.lowerBound < close.lowerBound {
					depth += 1
					i = nextOpen.upperBound
				} else {
					depth -= 1
					i = close.upperBound
					if depth == 0 { return String(markup[open.lowerBound..<close.upperBound]) }
				}
			}
			return ""
		}

		private static func occurrences(of needle: String, in haystack: String) -> Int {
			haystack.components(separatedBy: needle).count - 1
		}

		// MARK: - the scanners are pinned

		@Test("the scanners see boundaries, and count them once")
		func scannerSelfCheck() {
			let sample = """
			<div class="dd"><div class="dropdown"><button id="t" data-component-id="t">x</button>\
			<div class="dropdown__panel"><div data-component-id="p" data-event="click">\
			<button id="p-row" class="dd-row">r</button></div></div></div></div>
			"""
			#expect(Self.occurrences(of: "data-component-id=\"t\"", in: sample) == 1)
			#expect(Self.occurrences(of: "data-event=\"click\"", in: sample) == 1)
			#expect(Self.attribute("id", in: Self.openTags(in: sample).first { $0.contains("id=\"t\"") } ?? "") == "t")
			#expect(Self.attribute("data-component-id", in: "<div data-component-id-x=\"no\">") == nil,
			        "a prefixed attribute must not answer for `data-component-id`")
			let subtree = Self.divSubtree(in: sample, containing: "id=\"t\"")
			#expect(subtree.hasSuffix("</div>"), "the subtree reader must find the matching close")
			#expect(Self.occurrences(of: "data-event=\"click\"", in: subtree) == 1,
			        "the subtree must reach the panel, or the count proves nothing")
		}

		// MARK: - the trap

		@Test("the trigger is the boundary, and nothing else claims its id")
		func triggerKeepsItsBoundary() async {
			var checked = 0
			for (page, markup) in await Self.pages() {
				for (trigger, panel) in Self.converted + Self.composerSelectors {
					guard markup.contains("id=\"\(trigger)\"") else { continue }
					checked += 1
					#expect(Self.occurrences(of: " id=\"\(trigger)\"", in: markup) == 1,
					        "\(page): `\(trigger)` must appear as an id exactly once")
					#expect(Self.occurrences(of: "data-component-id=\"\(trigger)\"", in: markup) == 1,
					        "\(page): `\(trigger)` must be the data-component-id of exactly one element")
					#expect(!markup.contains("\(trigger)-trigger"),
					        "\(page): the component's `-trigger` id suffix must not come back")

					let button = Self.openTags(in: markup).first { $0.hasPrefix("<button") && $0.contains("id=\"\(trigger)\"") }
					#expect(button != nil, "\(page): the trigger must still be a button")
					#expect(Self.attribute("data-component-id", in: button ?? "") == trigger,
					        "\(page): the boundary must ride the trigger itself, not a wrapper")

					// the double-registration shape: `id:`/`onSelect:` handed to the
					// component on top of a self-wiring button emits a SECOND
					// `data-event` inside the control. measured: arc's `ArcButton`
					// emits none of its own, so exactly one is correct.
					let control = Self.divSubtree(in: markup, containing: "id=\"\(trigger)\"")
					#expect(Self.occurrences(of: "data-event=\"click\"", in: control) == 1,
					        "\(page): \(trigger) has \(Self.occurrences(of: "data-event=\"click\"", in: control)) click boundaries — the panel must be the only one")

					// the panel boundary is unchanged: same dispatch id, same event.
					#expect(Self.occurrences(of: "data-component-id=\"\(panel)\" data-event=\"click\"", in: control) == 1,
					        "\(page): the popover boundary `\(panel)` must survive exactly once")
				}
			}
			// eight visits: the four composer selectors, the main-model and
			// storage pickers (the settings page renders the storage section
			// inline, so `storage-pick-toggle` is reached from both pages) and the
			// profile skills picker. a rename that made every guard above skip
			// would otherwise pass this test by never running.
			#expect(checked == 8, "the boundary scan only reached \(checked) controls; the census is vacuous")
		}

		@Test("the component never renders a trigger of its own here")
		func triggerIsCallerRendered() async {
			for (page, markup) in await Self.pages() {
				#expect(!markup.contains("dropdown__trigger"),
				        "\(page): `dropdown__trigger` means the component rendered its own button — arc's trigger must be emitted verbatim")
				#expect(!markup.contains("dropdown__chevron"),
				        "\(page): the component injected a chevron into a caller-rendered trigger")
			}
		}

		@Test("the converted calls pass no register-only identity")
		func componentCallsAreRegisterOnly() throws {
			// `WebUIDropdown`'s caller-trigger initializer takes `id:` and
			// `onSelect:` but emits nothing for them — it only registers a handler.
			// arc's triggers already register theirs, so passing an id here would
			// silently double-register one component id.
			let source = try Self.viewsSource()
			var offenders: [String] = []
			var calls = 0
			var search = source.startIndex..<source.endIndex
			while let found = source.range(of: "WebUIDropdown(", range: search) {
				// the argument list only — the trigger closure opens at the first
				// `{`, and the `ArcButton` inside it legitimately carries `id:`.
				let tail = source[found.upperBound...]
				let arguments = String(tail.prefix(while: { $0 != "{" }))
				calls += 1
				if arguments.contains("onSelect:") || arguments.contains("id:") {
					offenders.append(String(source[found.lowerBound...].prefix(120)))
				}
				search = found.upperBound..<source.endIndex
			}
			// four call sites: the three settings pickers a render fixture reaches
			// (main model, storage, profile skills) plus the auxiliary-model picker,
			// which only renders while `auxEditingTask` is set — view state with no
			// fixture seam, so it is covered by this census rather than by markup.
			#expect(calls == 4, "expected 4 WebUIDropdown call sites; found \(calls)")
			#expect(offenders.isEmpty,
			        "these calls pass `id:`/`onSelect:`, which registers a second handler for an id the trigger already owns:\n\(offenders.joined(separator: "\n"))")
		}

		@Test("the scanner would catch a register-only call (its own precondition)")
		func registerOnlyScannerSelfCheck() {
			// a census that can never fire is not a census: this is the shape the
			// test above rejects, written the way a careless edit would write it.
			let bad = "WebUIDropdown(id: \"cb-ws-toggle\", onSelect: h) { trigger } panel: { rows }"
			let badHead = String(bad.dropFirst("WebUIDropdown(".count).prefix(while: { $0 != "{" }))
			#expect(badHead.contains("onSelect:") && badHead.contains("id:"))
			let good = "WebUIDropdown(isOpen: open) { ArcButton(id: \"t\", component: \"t\") { x } } panel: { rows }"
			let goodHead = String(good.dropFirst("WebUIDropdown(".count).prefix(while: { $0 != "{" }))
			#expect(!goodHead.contains("onSelect:") && !goodHead.contains("id:"),
			        "the scan must stop at the argument list, or a self-wiring trigger trips it")
		}

		// MARK: - the census

		@Test("the converted controls are the ones the placement allows")
		func convertedSetIsExact() async {
			let pages = await Self.pages()
			let all = pages.map(\.markup).joined()
			// the settings pickers run through the component …
			for (trigger, _) in Self.converted {
				#expect(all.contains("<div class=\"dropdown\"><button id=\"\(trigger)\""),
				        "\(trigger) no longer renders through WebUIDropdown")
			}
			// … and the composer selectors stay on arc's upward panel until a
			// placement option exists. this is the named capability gap, pinned so
			// a drive-by conversion cannot slip past the placement decision.
			let composer = pages.first { $0.name == "composer" }?.markup ?? ""
			for (trigger, panel) in Self.composerSelectors {
				#expect(composer.contains("id=\"\(trigger)\""), "\(trigger) must still render")
				#expect(!composer.contains("<div class=\"dropdown\"><button id=\"\(trigger)\""),
				        "\(trigger) was converted: `#main` clips a downward panel (overflow: hidden), so this control needs an upward placement the component does not offer")
				#expect(composer.contains("data-component-id=\"\(panel)\" data-event=\"click\""),
				        "\(panel) lost its popover boundary")
			}
		}

		@Test("the routing contract in Views.swift is unchanged")
		func boundaryCensusIsUnchanged() throws {
			// the recorded pre-count of the card: 37 inline `data-component-id`
			// spellings. `wire(...)` boundaries are not part of the count and are
			// pinned by `the trigger is the boundary` above. a change here is a
			// routing change and needs the card that owns it.
			let source = try Self.viewsSource()
			let count = Self.occurrences(of: "data-component-id", in: source)
			#expect(count == 37, "Views.swift carries \(count) `data-component-id` spellings, not the recorded 37")
		}

		@Test("the rows are not boundaries")
		func rowsStayIdOnly() async {
			// the engine reports `targetId` as the nearest id-bearing element
			// *inside* the boundary, so a row that became a boundary would swallow
			// its own dispatch. the panel wrapper owns the boundary; rows keep ids.
			for (page, markup) in await Self.pages() {
				for tag in Self.openTags(in: markup) {
					let tokens = (Self.attribute("class", in: tag) ?? "").split(whereSeparator: \.isWhitespace)
					guard tokens.contains("dd-row") else { continue }
					#expect(Self.attribute("data-component-id", in: tag) == nil,
					        "\(page): a dropdown row became its own boundary: \(tag.prefix(120))")
					#expect(Self.attribute("id", in: tag) != nil,
					        "\(page): a dropdown row lost its dispatch id: \(tag.prefix(120))")
				}
			}
		}

		// MARK: - no rule needs to move

		@Test("every class the component emits is defined by a linked sheet")
		func dropdownVocabularyResolves() {
			// the whole point of the caller-trigger form for arc: the component
			// contributes `div.dropdown`, `div.dropdown__panel` and nothing else,
			// so ChromeSheet needs no rule and no rule needs restyling. the page
			// links the framework sheet first, so that union is the real one.
			let markup = """
			<div class="dd">\
			<button id="probe-toggle" data-component-id="probe-toggle" class="dd-trigger" type="button">t</button>\
			</div>
			""" + WebUIDropdown(isOpen: true) { Text("trigger") } panel: { Text("panel") }.markup.html
			#expect(markup.contains("dropdown dropdown--open"), "the open state must paint through the wrapper class")
			let undefined = HTMLClassValidator.undefinedClasses(
				in: markup,
				extra: HTMLClassValidator.definedClasses(css: ThemeSheetAssets.text)
			)
			#expect(undefined.isEmpty,
			        "WebUIDropdown emits classes no linked sheet defines: \(undefined.sorted().joined(separator: ", "))")
			let framework = HTMLClassValidator.definedClasses()
			for name in ["dropdown", "dropdown--open", "dropdown__panel"] {
				#expect(framework.contains(name), "the framework sheet stopped defining .\(name)")
			}
		}
	}
}
