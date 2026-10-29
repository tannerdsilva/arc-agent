import Testing
import WebUI
@testable import ArcWebUI

/// the contract that lets a tree depth live in the DOM as a NUMBER while the
/// sheet keeps every layout decision.
///
/// if any of these fail, phase 7's conversion is a lie: the rows would carry a
/// value the stylesheet cannot read, or two `style` attributes would silently
/// drop all but the last declaration.
@Suite("style variables")
struct StyleVariableTests {

	private func markup(_ view: some WebUI.View) -> String {
		view.markup.html
	}

	@Test("a variable reaches the element as a single style attribute")
	func singleVariable() {
		let html = markup(Div(class: "ws-row") { Text("src") }.cssVar(.depth, "3"))
		#expect(html.contains("style=\"--ws-depth: 3;\""), "got: \(html)")
	}

	@Test("chained variables fold into ONE attribute, in declaration order")
	func chainedVariables() {
		let html = markup(
			Div(class: "ws-row ws-row--file") { Text("main.swift") }
				.cssVar(.depth, "2")
				.cssVar(.extra, "4px")
		)
		// two style attributes would mean the browser keeps only the last — the
		// depth would vanish and every row would collapse to one indent.
		#expect(html.components(separatedBy: "style=\"").count == 2, "exactly one style attribute: \(html)")
		let style = html.components(separatedBy: "style=\"").last?.components(separatedBy: "\"").first ?? ""
		#expect(style.contains("--ws-depth: 2;"), "depth survives: \(style)")
		#expect(style.contains("--ws-extra: 4px;"), "extra survives: \(style)")
		#expect(style.range(of: "--ws-depth")!.lowerBound < style.range(of: "--ws-extra")!.lowerBound,
		        "declaration order is source order: \(style)")
	}

	@Test("a variable and a component class coexist on one element")
	func variableWithClass() {
		let html = markup(
			Div(class: "ws-row") { Text("a") }
				.cssVar(.depth, "0")
				.attribute("data-scroll-key", "ws")
		)
		#expect(html.contains("class=\"ws-row\""), "class survives: \(html)")
		#expect(html.contains("data-scroll-key=\"ws\""), "attribute survives: \(html)")
		#expect(html.contains("--ws-depth: 0;"), "zero is emitted, not dropped: \(html)")
	}

	@Test("nested elements each get their own variable")
	func nestedElements() {
		let html = markup(
			Div(class: "tree") {
				Div(class: "ws-row") { Text("a") }.cssVar(.depth, "1")
				Div(class: "ws-row") { Text("b") }.cssVar(.depth, "2")
			}
		)
		#expect(html.contains("--ws-depth: 1;") && html.contains("--ws-depth: 2;"), "got: \(html)")
		#expect(html.components(separatedBy: "style=\"").count == 3, "one per row, none on the parent: \(html)")
	}
}