import Testing
import Foundation

/// the vocabulary census: the strings no-webui now has a type for must not come
/// back as strings.
///
/// each check names the defect it prevents, because a census that only counts
/// is a census nobody can act on.

extension ArcWebUITestRoot {
	@Suite("attribute vocabulary census", .serialized)
	struct VocabularyCensusTests {

		private static func viewsSource() throws -> String {
			let url = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
				.appendingPathComponent("Sources/ArcWebUI/Views.swift")
			return try String(contentsOf: url, encoding: .utf8)
		}

		@Test("every escaping seam names its source")
		func trustSeamsAreEnumerated() throws {
			let source = try Self.viewsSource()
			// `Raw(.trusted(…))` says only "trust me": it carried no reason, so the
			// only way to audit the escaping bypasses was to read the file.
			#expect(!source.contains("Raw(.trusted("),
			        "use `TrustedMarkup(_, from:)` so the seam states what makes it safe")
			let seams = source.components(separatedBy: "TrustedMarkup(").count - 1
			#expect(seams >= 10, "expected the known seams (markdown, plugin, icon, tool text); found \(seams)")
		}

		@Test("accessible names go through the typed aria modifier")
		func ariaIsTyped() throws {
			let source = try Self.viewsSource()
			#expect(!source.contains(#".attribute("aria-label""#),
			        "`.aria(.label(…))` carries the same bytes and cannot be misspelled")
			#expect(!source.contains(#".attribute("aria-pressed""#),
			        "`.aria(.pressed(.yes/.no))` is the typed spelling")
		}

		@Test("presence-only attributes are flags, not empty values")
		func presencesAreFlags() throws {
			let source = try Self.viewsSource()
			// `hidden=""` and `hidden` are not interchangeable with "absent", which is
			// why this was counterintuitive enough to need a type.
			#expect(!source.contains(".attribute(\"hidden\", \"\")"),
			        "`.flag(.hidden)` emits the bare attribute and nothing when false")
		}

		@Test("client wiring is one call, not two attributes")
		func wiringIsOneCall() throws {
			let source = try Self.viewsSource()
			// a component id and its event are one decision: pairing them by hand is
			// how a control renders, matches its element, and never fires.
			// every event declaration is typed now: `.wire` for the client-owned
			// path, `.on`/`.onClick` for the server-owned one.
			#expect(!source.contains(#".attribute("data-event""#),
			        "`.wire(_:)` emits both attributes together")
		}

		@Test("hand-written style attributes carry no layout decisions")
		func styleAttributesAreData() throws {
			let source = try Self.viewsSource()
			// the rule: a `style` attribute may hold `--*` declarations and nothing
			// else — the arithmetic belongs to the sheet. the phase-7 builders still
			// hand-write a few (`padding-left`, `margin-top`); this pin is written to
			// shrink to zero as they convert, so it is a ratchet, not a rubber stamp.
			let inline = source.components(separatedBy: "style=\\").count - 1
			#expect(inline <= 20, "inline style occurrences grew: \(inline)")
		}
	}
}
