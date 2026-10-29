import Foundation
import Testing

import ArcTheme
import WebUI
import WebUIDesignSystem
@testable import ArcWebUI

// ADOPT B2.1 — the field family renders through `WebUIField`.
//
// two invariants survive the conversion and neither is visible from a rendering
// test alone: no hand-written `Div { Label…; Input(field:) }` triple comes back
// into `Views.swift`, and the vocabulary `WebUIField` emits resolves against the
// sheets the page actually links. the second is what lets arc's own sheet stay
// out of the field family: the framework sheet already defines every `.field*`
// selector, and `HTMLClassValidator` unions it with the host sheet.
@Suite("field family adoption")
struct FieldFamilyAdoptionTests {

	private static func viewsSource() throws -> String {
		let url = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()   // ArcAgentWebUITests
			.deletingLastPathComponent()   // Tests
			.deletingLastPathComponent()   // repo root
			.appendingPathComponent("Sources/ArcWebUI/Views.swift")
		return try String(contentsOf: url, encoding: .utf8)
	}

	/// every control bound with `field:` that does NOT render through
	/// `WebUIField`, each for a stated reason. this list is the census of what
	/// the family legitimately leaves hand-written; a new entry is a regression,
	/// a missing one means a field silently stopped being adopted.
	///
	/// - unlabelled controls (10): a menu rename box, the two inline
	///   add-category/add-column/add-card forms, the clarify free-text box, the
	///   composer, a hidden edit id, the memory editor, and the workspace
	///   new-file name. none has a label, so `WebUIField` would add an empty
	///   `.field` wrapper and change their layout for nothing.
	/// - bespoke required-tag fields (2): `skill-name-input` and
	///   `skill-desc-input` carry a `FormLabel` with a `req-tag` badge plus an
	///   `invalidField`/`errSpan` pair. `required: true` would replace the
	///   visible "Required" badge with a `::after` marker — a text change, not a
	///   structural one — so they stay hand-written for B3's typed vocabulary.
	/// - a dropdown (1): `profile-ctx-effort` is the `Select` family, B2.2's card.
	private static let unadopted = [
		"cat-rename-input", "cat-name-input", "cat-color-input",
		"kb-addcol-name", "kb-addcard-name", "clarify-input",
		"composer-input", "storage-edit-id", "mem-content", "ws-new-name",
		"skill-name-input", "skill-desc-input",
		"profile-ctx-effort",
	]

	private static func regex(_ pattern: String) throws -> NSRegularExpression {
		try NSRegularExpression(pattern: pattern)
	}

	private static func labelLine() throws -> NSRegularExpression {
		try regex(#"^[ \t]*Label\("(?:[^"\\]|\\.)*", for: "(?:[^"\\]|\\.)*"\)[ \t]*$"#)
	}

	private static func controlLine() throws -> NSRegularExpression {
		try regex(#"^[ \t]*(Input|TextArea)\(field: "(?:[^"\\]|\\.)*""#)
	}

	private static func matches(_ re: NSRegularExpression, _ line: String) -> Bool {
		re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
	}

	/// a hand-written field triple: `Div {` immediately followed by a
	/// `Label("…", for: "…")` and then a control bound to the same identity.
	/// `Select` is excluded — that family belongs to B2.2.
	static func handWrittenTriples(in source: String) throws -> [Int] {
		let lines = source.components(separatedBy: "\n")
		let label = try labelLine()
		let control = try controlLine()
		var found: [Int] = []
		for i in 0..<max(0, lines.count - 2) where lines[i].trimmingCharacters(in: .whitespaces) == "Div {" {
			guard matches(label, lines[i + 1]) else { continue }
			guard matches(control, lines[i + 2]) else { continue }
			found.append(i + 1)
		}
		return found
	}

	@Test("no hand-written field triple survives in Views.swift")
	func noHandWrittenTriples() throws {
		let triples = try Self.handWrittenTriples(in: Self.viewsSource())
		#expect(triples.isEmpty,
		        "these lines still hand-write `Div { Label; Input(field:) }` — render them through `WebUIField`: \(triples)")
	}

	@Test("the scanner sees a hand-written triple (its own precondition)")
	func scannerSelfCheck() throws {
		// a probe that can silently see nothing would pass the test above for the
		// wrong reason. this pins the three-line shape against a synthetic sample.
		let sample = """
		Div {
		    Label("Name", for: "probe-input")
		    Input(field: "probe-input", placeholder: "x", type: nil)
		}
		"""
		#expect(try Self.handWrittenTriples(in: sample).count == 1)
		// a select triple is B2.2's shape and must not be reported here.
		let select = """
		Div {
		    Label("Effort", for: "probe-effort")
		    Select(field: "probe-effort", options: [])
		}
		"""
		#expect(try Self.handWrittenTriples(in: select).isEmpty)
	}

	@Test("the converted family is actually on the adopted path")
	func adoptionIsNotVacuous() throws {
		let source = try Self.viewsSource()
		let fields = source.components(separatedBy: "WebUIField(label:").count - 1
		#expect(fields >= 33, "expected the labelled fields to render through WebUIField; found \(fields)")
	}

	@Test("the controls outside WebUIField are exactly the enumerated shapes")
	func remainderCensus() throws {
		let source = try Self.viewsSource()
		let fieldIDs = Set(try Self.identifiers(
			in: source,
			pattern: #"(?:Input|TextArea|Select)\(field: "([^"]+)""#
		))
		let adopted = Set(try Self.identifiers(in: source, pattern: #"controlID: "([^"]+)""#))
		let left = fieldIDs.subtracting(adopted)
		#expect(left == Set(Self.unadopted),
		        """
			the set of `field:`-bound controls outside WebUIField changed:
			unexpected: \(left.subtracting(Self.unadopted).sorted())
			missing:    \(Set(Self.unadopted).subtracting(left).sorted())
			""")
	}

	@Test("every class WebUIField emits is defined by a linked sheet")
	func fieldVocabularyResolves() {
		// the maximal render: label row with a required marker, an error note, a
		// counter, and an error helper. every branch of `WebUIField.render` that
		// can add a class is taken here, so the census below cannot miss one.
		let field = WebUIField(
			label: "Probe", controlID: "probe-field", required: true,
			note: "note", noteKind: .error, count: "0 / 8",
			helper: "helper", helperIsError: true
		) {
			Input(field: "probe-field")
		}
		let markup = field.markup.html
		// the union the served page has: the framework sheet plus arc's own.
		let undefined = HTMLClassValidator.undefinedClasses(
			in: markup,
			extra: HTMLClassValidator.definedClasses(css: ThemeSheetAssets.text)
		)
		#expect(undefined.isEmpty,
		        """
			WebUIField emits classes no linked sheet defines — arc's sheet must carry \
			the missing rules, or the family cannot be adopted:
			\(undefined.sorted().joined(separator: "\n"))
			""")
		// and the vocabulary really is the framework's, not a duplicate arc must own.
		let framework = HTMLClassValidator.definedClasses()
		for name in ["field", "field__row", "field__label", "field__label--required",
		             "field__hint", "field__hint--error", "field__count",
		             "field__helper", "field__helper--error"] {
			#expect(framework.contains(name), "the framework sheet stopped defining .\(name)")
		}
	}

	private static func identifiers(in source: String, pattern: String) throws -> [String] {
		let re = try regex(pattern)
		let ns = source as NSString
		return re.matches(in: source, range: NSRange(location: 0, length: ns.length))
			.map { ns.substring(with: $0.range(at: 1)) }
	}
}