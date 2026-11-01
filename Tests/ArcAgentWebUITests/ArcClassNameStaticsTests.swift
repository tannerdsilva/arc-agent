import ArcTheme
import Foundation
import Testing

// the generated-statics ratchet.
//
// `ArcClassNameStatics.swift` is produced from `ArcClass.swift` by
// `Scripts/gen-classname-statics.py`, so the only way the two files stay in step
// is if something checks them against each other. adding a case to the enum and
// forgetting to regenerate does not break the build — it leaves that token
// spellable only as a string, which is a silent hole in the vocabulary rather
// than a compile error. this suite closes that hole by comparing the two
// declarations directly, in the same source-scanning style as the adoption and
// audit suites beside it.

extension ArcWebUITestRoot {
	@Suite("class name statics", .serialized)
	struct ArcClassNameStaticsTests {

		/// one file from `Sources/ArcTheme`, found relative to this test file so
		/// the suite reads the tree it is compiled into rather than a path that
		/// only exists on one machine.
		static func source(_ file: String) throws -> String {
			let root = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()   // ArcAgentWebUITests
				.deletingLastPathComponent()   // Tests
				.deletingLastPathComponent()   // package root
				.appendingPathComponent("Sources/ArcTheme/\(file)")
			return try String(contentsOf: root, encoding: .utf8)
		}

		@Test("every case has a static, and no static is orphaned")
		func staticsMirrorTheCaseList() throws {
			let enumText = try Self.source("ArcClass.swift")
			let staticText = try Self.source("ArcClassNameStatics.swift")

			// no `^` anchor here: swift's `Regex` anchors `^` to the start of the
			// whole string, not each line (`String.matches(of:)` does not imply
			// `.anchorsMatchLines`). the leading tab is the anchor instead, which
			// is also what keeps a commented-out `case` from matching.
			let caseNames = Set(
				enumText.matches(of: /\tcase `?([A-Za-z0-9_]+)`? = "/).map { String($0.1) }
			)
			let staticNames = Set(
				staticText.matches(of: /public static var `?([A-Za-z0-9_]+)`?: ClassName/).map { String($0.1) }
			)

			// a scan that matches nothing would make the comparison below pass
			// vacuously if the enum's spelling ever changes.
			#expect(!caseNames.isEmpty, "the case scan matched nothing — the enum's declaration style changed")
			#expect(!staticNames.isEmpty, "the static scan matched nothing — the statics' declaration style changed")

			let missing = caseNames.subtracting(staticNames).sorted()
			let orphaned = staticNames.subtracting(caseNames).sorted()
			#expect(missing.isEmpty && orphaned.isEmpty, """
				the statics and the case list disagree — regenerate
				`Sources/ArcTheme/ArcClassNameStatics.swift` with `Scripts/gen-classname-statics.py`:
				missing (a case with no static): \(missing.joined(separator: ", "))
				orphaned (a static with no case): \(orphaned.joined(separator: ", "))
				""")

			#expect(staticNames.count == ArcClass.allCases.count, """
				\(staticNames.count) statics against \(ArcClass.allCases.count) cases — \
				the generated file is stale; regenerate it rather than hand-editing
				""")
		}
	}
}
