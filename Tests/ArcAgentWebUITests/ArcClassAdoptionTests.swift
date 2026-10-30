import ArcTheme
import Foundation
import Testing
import WebUIDesignSystem
@testable import ArcWebUI

// the class-vocabulary adoption ratchet.
//
// `ArcClass` covers every token the sheet declares, and the 952 sites whose
// class value was a plain literal now name a case. what is left is debt of two
// shapes, and this suite pins both so it may only shrink:
//
//   1. **concatenated values** — `class: "approval-card" + (cond ? " open" : "")`.
//      the first half is a token, the second is a state suffix; expressing it as
//      a case list needs the conditional to move onto a `.classes(...)` chain
//      *after* the call, which a text migration cannot place reliably.
//   2. **interpolated values** — `"queue-status\(statusCls)"`, where the whole
//      token is computed from state. these want a component-level variant axis,
//      not a vocabulary entry (the `SpacingAxis` lesson: same concept, one name).
//   3. **mixed values** — `"approval-card visible"`, where one token is a real
//      case and its sibling is undeclared. the whole value has to stay a string:
//      naming half of it would change the call shape, and the undeclared half
//      would still render unstyled.
//
// and one shape that is not debt at all: the tokens `approval-title`, `btn`,
// `insights-main`, `visible` and their siblings are declared by **no sheet**, so
// `ArcClass` cannot name them. they render unstyled today; deleting the sites or
// writing the rules is a design decision, not a migration.
extension ArcWebUITestRoot {
	@Suite("class vocabulary adoption", .serialized)
	struct ArcClassAdoptionTests {

		/// static class tokens still spelled as strings, each one either a
		/// concatenation's first half or a token no sheet declares.
		static let residualStaticTokens: Set<String> = [
			// concatenation first halves — a token plus a state suffix
			"approval-card", "chat-menu", "clarify-card", "dd-dot", "dd-list", "dd-pop",
			"dd-pop-model", "file-pop", "main-scroll", "msg-action-btn", "panel-head",
			"tc-detail", "todo-card", "tool-btn", "composer-bar", "clarify-pill",
			// declared by no sheet — ArcClass cannot name them
			"approval-title", "arch-ico", "btn", "chat-menu-items", "clarify-title",
			"ctx-swatches", "dd-list-profile", "dd-pop-ws", "insights-main",
			"msg-copy-btn", "panel-note", "pill-other", "queue-card",
			"queue-loop-count-label", "skill-cat-title", "task-ctrl-main",
			"thinking-detail", "todo-list", "visible", "ws-head", "ws-menu", "yolo-text",
		]

		/// sites whose class value is interpolated (`\\(` inside the literal).
		static let residualInterpolatedSites = 28

		static func sources() -> [(String, String)] {
			let root = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()   // ArcAgentWebUITests
				.deletingLastPathComponent()   // Tests
				.deletingLastPathComponent()   // package root
				.appendingPathComponent("Sources/ArcWebUI")
			guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
				return []
			}
			var out: [(String, String)] = []
			for case let url as URL in walk where url.pathExtension == "swift" {
				if let text = try? String(contentsOf: url, encoding: .utf8) {
					out.append((url.lastPathComponent, text))
				}
			}
			return out.sorted { $0.0 < $1.0 }
		}

		@Test("the only static class strings left are the pinned residual set")
		func residualStaticTokensOnly() {
			var found = Set<String>()
			for (_, text) in Self.sources() {
				for match in text.matches(of: /class:\s*"((?:[^"\\]|\\.)*)"/) {
					let body = String(match.1)
					if body.contains("\\(") { continue }
					for token in body.split(separator: " ") { found.insert(String(token)) }
				}
			}
			let unexpected = found.subtracting(Self.residualStaticTokens)
			#expect(unexpected.isEmpty, """
				class tokens spelled as strings that ArcClass can name — name the case instead:
				\(unexpected.sorted().joined(separator: "\n"))
				""")
			let stale = Self.residualStaticTokens.subtracting(found)
			#expect(stale.isEmpty, """
				pinned as residual, but no longer present — shrink the list:
				\(stale.sorted().joined(separator: "\n"))
				""")
		}

		@Test("interpolated class values are a pinned count")
		func interpolatedClassValuesArePinned() {
			var count = 0
			for (_, text) in Self.sources() {
				for match in text.matches(of: /class:\s*"((?:[^"\\]|\\.)*)"/) where String(match.1).contains("\\(") {
					count += 1
				}
			}
			#expect(count == Self.residualInterpolatedSites,
			        "interpolated class sites: \(count), pinned \(Self.residualInterpolatedSites) — a new one is a regression, a drop means shrink the pin")
		}

	}
}
