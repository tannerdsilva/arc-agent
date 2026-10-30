import Testing
import Foundation

/// the invariant `FieldID` exists to hold, checked at the source level.
///
/// the defect is not "a control with two attributes" — it is *the same literal
/// written twice*, because those two copies can drift and nothing in the
/// toolchain notices. `Input(id:name:)` still exists and is still correct for a
/// control whose id and name genuinely differ; what must never come back is the
/// redundant pair.

extension ArcWebUITestRoot {
	@Suite("field identity census", .serialized)
	struct FieldIdentityCensusTests {

		private static func viewsSource() throws -> String {
			let url = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()   // ArcAgentWebUITests
				.deletingLastPathComponent()   // Tests
				.deletingLastPathComponent()   // repo root
				.appendingPathComponent("Sources/ArcWebUI/Views.swift")
			return try String(contentsOf: url, encoding: .utf8)
		}

		/// every `<Control>(id: "…" … name: "…")` in the file, as (kind, id, name).
		private static func controlPairs(in source: String) throws -> [(String, String, String)] {
			let pattern = #"(Input|TextArea|Select)\(\s*id:\s*"([^"]*)"[\s\S]{0,240}?name:\s*"([^"]*)""#
			let regex = try NSRegularExpression(pattern: pattern)
			let ns = source as NSString
			return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { m in
				guard m.numberOfRanges == 4 else { return nil }
				return (ns.substring(with: m.range(at: 1)),
				        ns.substring(with: m.range(at: 2)),
				        ns.substring(with: m.range(at: 3)))
			}
		}

		@Test("no control spells the same literal as both id and name")
		func noRedundantPairs() throws {
			let source = try Self.viewsSource()
			let redundant = try Self.controlPairs(in: source).filter { $0.1 == $0.2 }
			#expect(redundant.isEmpty,
			        "these controls write one identity twice — use `field:`: \(redundant.map { "\($0.0)(\($0.1))" })")
		}

		@Test("the form library is actually in use")
		func fieldInitializersInUse() throws {
			// a vacuous pass would be a census that guards nothing: if `field:` were
			// removed wholesale, `noRedundantPairs` above would also start failing —
			// but only because the pairs came back, which is easy to "fix" by
			// diverging the two literals. this asserts the typed path is the path.
			let source = try Self.viewsSource()
			let uses = source.components(separatedBy: "field:").count - 1
			#expect(uses >= 30, "expected the forms to use `field:`; found \(uses) uses")
		}

		@Test("a control whose id and name differ is still allowed")
		func divergentPairIsLegal() throws {
			// the census forbids redundancy, not divergence. this is the shape a
			// client-only control would legitimately need, and it must not trip the
			// first test.
			let sample = #"Input(id: "display-only", name: "posted-name", type: .text)"#
			let pairs = try Self.controlPairs(in: sample)
			#expect(pairs.count == 1)
			#expect(pairs.first?.1 != pairs.first?.2, "the census must not call a divergent pair redundant")
		}
	}
}
