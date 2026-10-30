import Testing

import ArcTheme
import WebUI
import WebUIDesignSystem
@testable import ArcWebUI

// the compile-time link between arc's class vocabulary and the sheet the server
// ships.
//
// `ArcClass` is generated (its header says so), and a generated file with no
// guard is a file that drifts: a rule added to `Theme.css` and not to the enum
// is a class the compiler cannot name, and a case left behind after its rule is
// deleted is a token that renders unstyled while type-checking fine. both are
// silent at runtime, so both are asked here — of the same parser every other
// sheet test uses, `HTMLClassValidator.definedClasses(css:)`, run over the bytes
// the server actually serves.
//
// the last test is the other half of the slice: the delegating initializers are
// only worth having if they emit what the literal spelling emits, so each one is
// rendered against its string twin and the markup compared.

extension ArcWebUITestRoot {
	@Suite("arc class audit", .serialized)
	struct ArcClassAuditTests {

		/// the tokens the enum deliberately does not carry.
		///
		/// empty, and that is the measured answer rather than an omission: every
		/// one of the 618 tokens the sheet declares can be a case. the two whose
		/// camelCase name is a swift keyword (`open`, `switch`) are backticked and
		/// still spell `.open`/`.switch` at a call site, so they need no exception.
		///
		/// a name belongs here only when it cannot be a case at all — the shape
		/// that would justify one is a class no rule declares, added only by client
		/// js at runtime and kept in the sheet for that reason. each entry added
		/// here carries its reason in a comment, and this set is the only place
		/// such a name may live.
		static let exceptions: Set<String> = []

		/// the sheet's declared token count, measured when the enum was generated
		/// — a throwaway script over the built `ThemeSheetAssets.text`, 618 tokens.
		///
		/// this literal is not the guard by itself: `sheetStillMatchesTheMeasurement`
		/// re-counts the live sheet, so a sheet edit fails there with the difference
		/// rather than quietly redefining what the enum was built from.
		static let declaredTokenCount = 618

		// MARK: - both directions

		@Test("no case without a rule")
		func noCaseWithoutARule() {
			let declared = HTMLClassValidator.definedClasses(css: ThemeSheetAssets.text)
			let cases = Set(ArcClass.allCases.map(\.token))
			let invented = cases.subtracting(declared)
			#expect(invented.isEmpty, """
				ArcClass carries tokens the served sheet declares no rule for — the \
				compiler would accept a class that renders unstyled:
				\(invented.sorted().joined(separator: "\n"))
				""")
		}

		@Test("no rule without a case")
		func noRuleWithoutACase() {
			let declared = HTMLClassValidator.definedClasses(css: ThemeSheetAssets.text)
			let cases = Set(ArcClass.allCases.map(\.token))
			let unnameable = declared.subtracting(cases).subtracting(Self.exceptions)
			#expect(unnameable.isEmpty, """
				the served sheet declares classes ArcClass cannot name — add the case, \
				or an exception and its reason:
				\(unnameable.sorted().joined(separator: "\n"))
				""")
		}

		@Test("the case count is the declared count")
		func countIsTheDeclaredCount() {
			#expect(ArcClass.allCases.count == Self.declaredTokenCount - Self.exceptions.count)
		}

		@Test("the live sheet still declares the measured count")
		func sheetStillMatchesTheMeasurement() {
			let declared = HTMLClassValidator.definedClasses(css: ThemeSheetAssets.text)
			#expect(declared.count == Self.declaredTokenCount, """
				the sheet declares \(declared.count) classes, not the \
				\(Self.declaredTokenCount) ArcClass was generated from — regenerate \
				the enum (see its header) and update the measurement.
				""")
		}

		// MARK: - the enum's own shape

		@Test("case names are unique and every token round-trips")
		func casesRoundTrip() {
			#expect(Set(ArcClass.allCases.map(\.token)).count == ArcClass.allCases.count)
			for arcClass in ArcClass.allCases {
				#expect(ArcClass(rawValue: arcClass.token) == arcClass)
				#expect(arcClass.token.isEmpty == false)
			}
		}

		// MARK: - the delegating initializers

		@Test("a declared class reads the same as its literal spelling")
		func delegatingInitializersEmitTheSameBytes() {
			// every pair below is the same render written twice: once through the
			// `ArcClass` initializer, once through the `class:` string it delegates
			// to. equality is the whole contract — the delegating initializer exists
			// to change what a call site says, never what the page contains.
			let pairs: [(String, String)] = [
				(
					Div(.setRow, id: "probe") { Text("x") }.markup.html,
					Div(id: "probe", class: "set-row") { Text("x") }.markup.html
				),
				(
					Div(id: "probe", class: .setRow) { Text("x") }.markup.html,
					Div(id: "probe", class: "set-row") { Text("x") }.markup.html
				),
				(
					Span(.queueStatus) { Text("x") }.markup.html,
					Span(class: "queue-status") { Text("x") }.markup.html
				),
				(
					Section(id: "probe", class: .setSection) { Text("x") }.markup.html,
					Section(id: "probe", class: "set-section") { Text("x") }.markup.html
				),
				(
					Header(class: .setRow) { Text("x") }.markup.html,
					Header(class: "set-row") { Text("x") }.markup.html
				),
				(
					Element(.div, class: .setRow, id: "probe") { Text("x") }.markup.html,
					Element(.div, class: "set-row", id: "probe") { Text("x") }.markup.html
				),
				(
					Form(method: .get, class: .setRow) { Text("x") }.markup.html,
					Form(method: .get, class: "set-row") { Text("x") }.markup.html
				),
				(
					Heading("x", level: .h2, class: .detailTitle).markup.html,
					Heading("x", level: .h2, class: "detail-title").markup.html
				),
				(
					Label("x", for: "probe", class: .setRow).markup.html,
					Label("x", for: "probe", class: "set-row").markup.html
				),
				(
					Link("x", href: "/probe", class: .setRow).markup.html,
					Link("x", href: "/probe", class: "set-row").markup.html
				),
				(
					ArcButton("x", id: "probe", class: .primaryBtn).markup.html,
					ArcButton("x", id: "probe", class: "primary-btn").markup.html
				),
				(
					ArcButton(id: "probe", class: .iconMini) { Text("x") }.markup.html,
					ArcButton(id: "probe", class: "icon-mini") { Text("x") }.markup.html
				),
				(
					FieldLabel(.setRow) { Text("x") }.markup.html,
					FieldLabel(class: "set-row") { Text("x") }.markup.html
				),
				(
					DetailTitle("x", class: .setRow).markup.html,
					DetailTitle("x", class: "set-row").markup.html
				),
				(
					Div { Text("x") }.classes(.setRow, .active).markup.html,
					Div { Text("x") }.classes(ClassName("set-row"), ClassName("active")).markup.html
				),
				(
					Div { Text("x") }.addClass(.setRow).markup.html,
					Div { Text("x") }.addClass(ClassName("set-row")).markup.html
				),
			]
			for (index, pair) in pairs.enumerated() where pair.0 != pair.1 {
				Issue.record("""
					pair \(index): a declared class rendered differently from its \
					literal spelling
					declared: \(pair.0)
					literal:  \(pair.1)
					""")
			}
		}
	}
}
