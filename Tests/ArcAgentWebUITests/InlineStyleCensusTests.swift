import Foundation
import Testing
import WebUICore

/// the inline-margin census.
///
/// arc spelled every margin as raw style text because `margin(_ all: Int)` was the
/// only typed door. the pin now carries `Edge` + `SpaceToken` overloads, so a value
/// that sits on the design system's 4px grid is written `.margin(.top, .three)`
/// instead of `.attribute("style", "margin-top:12px")`.
///
/// what remains below is *debt*, not a blessing. eleven sites moved; the fifteen
/// still here fall into two classes, spelled out at `everyLengthIsJustified`:
/// values the token scale cannot express, and multi-value shorthands a future
/// slice can still reach. this census pins the list so it may only shrink — a new
/// raw margin fails here rather than accumulating quietly.

extension ArcWebUITestRoot {
	@Suite("inline style census", .serialized)
	struct InlineStyleCensusTests {

		// MARK: - the shape of a finding

		/// one raw margin declaration, as found in the sources.
		struct Site: CustomStringConvertible {
			/// path relative to `Sources/ArcWebUI`.
			let file: String
			let line: Int
			/// the style text exactly as written.
			let style: String
			/// every length in the declaration, in px, in source order.
			let lengths: [Int]
			/// tokens the parser could not read as a px length — a new unit, an
			/// interpolation. always a failure, never a silent skip: a census that
			/// cannot read a value must not report the list as clean.
			let unparsed: [String]

			var location: String { "\(file):\(line)" }

			var description: String {
				"\(location)  .attribute(\"style\", \"\(style)\")  -> [\(lengths.map { "\($0)px" }.joined(separator: ", "))]"
			}
		}

		// MARK: - the pin

		/// the rule a reader of a failure needs: the door is typed unless the value is
		/// genuinely outside the scale.
		static let rule =
			"record it here only if the value is genuinely outside the design system's scale; otherwise use the typed modifier"

		/// the exact number of raw margin sites that remain.
		///
		/// 17, not the 15 this was pinned at before the tessera merge: that line
		/// added two `margin-top:14px` sites, and a top-only margin has no door —
		/// `.margin(_:)` takes one uniform length. they are the next slice's work,
		/// not a new allowance.
		static let expectedCount = 17

		/// every px length those sites spell. `0` and `4` are on the design system's 4px
		/// grid, so a future slice can still move them; `2`, `6`, `10` and `14` have no
		/// `--space-N` token and cannot move until the design system grows one.
		static let expectedLengths: Set<Int> = [0, 2, 4, 6, 10, 14]

		/// lengths a token exists for today: `--space-N` is N x 4px and `SpaceToken` is
		/// the pin's own list of N. derived, never hardcoded, so a scale change re-opens
		/// this question instead of silently blessing it.
		static var tokenGrid: Set<Int> {
			Set(SpaceToken.allCases.map { $0.rawValue * 4 })
		}

		// MARK: - the scan

		/// parse every `.attribute("style", "…")` whose text carries a `margin`
		/// declaration. `El("h3", [("style", …)])` tuple attributes are out of scope:
		/// they have no typed door to move to.
		static func sites(in files: [(name: String, text: String)]) -> [Site] {
			let marker = #".attribute("style", ""#
			var found: [Site] = []
			for file in files {
				for (index, line) in file.text
					.split(separator: "\n", omittingEmptySubsequences: false)
					.enumerated() {
					let trimmed = line.trimmingCharacters(in: .whitespaces)
					// a comment may quote the pattern; only code counts.
					guard !trimmed.hasPrefix("//") else { continue }
					guard let start = trimmed.range(of: marker) else { continue }
					let afterMarker = trimmed[start.upperBound...]
					// the value ends at the closing quote of the call: `")`.
					guard let end = afterMarker.range(of: "\")") else { continue }
					let style = String(afterMarker[..<end.lowerBound])
					guard style.contains("margin") else { continue }
					let parsed = lengths(in: style)
					guard !parsed.px.isEmpty || !parsed.unparsed.isEmpty else { continue }
					found.append(Site(file: file.name, line: index + 1, style: style,
					                  lengths: parsed.px, unparsed: parsed.unparsed))
				}
			}
			return found
		}

		/// every length in every `margin` / `margin-*` declaration of a style text.
		///
		/// a bare `0` is a zero length with no unit — the shorthands (`margin:0 0 6px`)
		/// rely on it, so a parser that only understood `Npx` would miss half the
		/// values and under-report the grid.
		private static func lengths(in style: String) -> (px: [Int], unparsed: [String]) {
			var px: [Int] = []
			var unparsed: [String] = []
			for declaration in style.split(separator: ";") {
				let parts = declaration.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
				guard parts.count == 2 else { continue }
				let property = parts[0].trimmingCharacters(in: .whitespaces)
				guard property == "margin" || property.hasPrefix("margin-") else { continue }
				for token in parts[1].split(separator: " ", omittingEmptySubsequences: true) {
					let value = String(token).trimmingCharacters(in: .whitespaces)
					if value == "0" {
						px.append(0)
					} else if value.hasSuffix("px"), let n = Int(value.dropLast(2)) {
						px.append(n)
					} else if !value.isEmpty {
						unparsed.append(value)
					}
				}
			}
			return (px, unparsed)
		}

		/// the web UI sources, read from disk beside this test file.
		///
		/// recursive: a raw margin in a subdirectory is still a raw margin, and a
		/// non-recursive scan would let one hide the moment the file moves.
		private static func webUISources() throws -> [(name: String, text: String)] {
			let root = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()   // ArcAgentWebUITests
				.deletingLastPathComponent()   // Tests
				.deletingLastPathComponent()   // package root
				.appendingPathComponent("Sources/ArcWebUI")
			guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
				Issue.record("expected the web UI sources beside the tests at \(root.path)")
				return []
			}
			let prefix = root.path + "/"
			var files: [(name: String, text: String)] = []
			for case let url as URL in walker where url.pathExtension == "swift" {
				let name = url.path.replacingOccurrences(of: prefix, with: "")
				files.append((name, try String(contentsOf: url, encoding: .utf8)))
			}
			// an empty or moved directory would make every pin below pass vacuously.
			try #require(files.count > 10, "expected the web UI sources beside the tests, found \(files.count)")
			return files.sorted { $0.name < $1.name }
		}

		// MARK: - the pins

		@Test("seventeen raw margin sites remain, and no more")
		func rawMarginCountIsPinned() throws {
			let found = Self.sites(in: try Self.webUISources())
			#expect(found.count == Self.expectedCount,
			        "raw margin sites: found \(found.count), pinned at \(Self.expectedCount).\n    \(found.map(\.description).joined(separator: "\n    "))\n    a new site is a regression — \(Self.rule).")
			// a value the census cannot read would otherwise count as "on the list".
			let unreadable = found.filter { !$0.unparsed.isEmpty }
			#expect(unreadable.isEmpty,
			        "the census cannot read these margin values: \(unreadable.map(\.description)) — \(Self.rule)")
		}

		@Test("the remaining margin lengths are exactly the pinned set")
		func remainingLengthsArePinned() throws {
			// the point of pinning the *set* rather than only the count: a site that
			// swaps `6px` for `7px` keeps the count at nineteen and still breaks the
			// design system. the count test alone would not see it.
			let found = Self.sites(in: try Self.webUISources())
			let values = Set(found.flatMap(\.lengths))
			#expect(values == Self.expectedLengths,
			        "remaining margin lengths: \(values.sorted()), pinned at \(Self.expectedLengths.sorted()).\n    offenders:\n    \(found.filter { $0.lengths.contains { !Self.expectedLengths.contains($0) } }.map(\.description).joined(separator: "\n    "))\n    \(Self.rule).")
		}

		@Test("every remaining length is off the token scale, or movable debt")
		func everyLengthIsJustified() throws {
			// the two classes of length, stated so the list reads as debt:
			//
			//   movable — 0 and 4. both sit on the 4px grid (0 is the `margin:0` form,
			//             which `.margin(0)` already expresses, and 4 is `--space-1`).
			//             a future slice can move every one of these to the typed door;
			//             they are here only because no slice has reached them yet.
			//   off-grid — 2, 6, 10 and 14. no `--space-N` token is worth these values
			//             (the scale is N x 4px, so the nearest are 0/4 for 2, 4/8 for
			//             6, 8/12 for 10, 12/16 for 14). they cannot move without
			//             changing the rendered pixels, which is a design decision, not
			//             a refactor.
			//
			// the four `margin:0` sites this list used to hold back (the memory panel's
			// `Heading`s and the chat-header action group) are migrated. they were pinned
			// because a modifier there appeared to SIGSEGV the debug test build — 20/20 runs
			// in one session — and that turned out to be a STALE-BUILD PHANTOM: after
			// `swift package clean` the same patch rendered the page in full, 0/20 crashes,
			// and the only diff was this attribute. the lesson lives in the
			// `systematic-debugging` skill: a loop that only reproduces from an inherited
			// `.build` is not a reproducer.
			let movable: Set<Int> = [0, 4]
			let offGrid: Set<Int> = [2, 6, 10, 14]

			let values = Set(try Self.sites(in: try Self.webUISources()).flatMap(\.lengths))
			let unexplained = values.subtracting(movable).subtracting(offGrid)
			#expect(unexplained.isEmpty,
			        "these margin lengths are neither movable debt nor a known off-grid value: \(unexplained.sorted()) — \(Self.rule)")

			// the off-grid claim must be true of *this* pin, not of a remembered scale:
			// if the design system ever grows a token worth one of these, the site
			// becomes migratable and this test should stop excusing it.
			let reachable = offGrid.intersection(Self.tokenGrid)
			#expect(reachable.isEmpty,
			        "the token scale now covers \(reachable.sorted())px — those sites can use the typed modifier")

			// and every length the scale *does* cover is either already typed or on the
			// movable list. this is what keeps "off-grid" from quietly absorbing a
			// value that has a token.
			let covered = values.intersection(Self.tokenGrid).union(values.intersection([0]))
			#expect(covered == movable,
			        "expected the token-covered lengths to be exactly the movable debt; got \(covered.sorted())")
		}

		@Test("the typed margin door is actually in use, so the census guards a live surface")
		func typedMarginDoorIsUsed() throws {
			// if every site were still raw, the count pin above would be the only
			// guard — and it would pass by never moving. this asserts the migration
			// this census exists to protect actually happened.
			let text = try Self.webUISources().map(\.text).joined()
			#expect(text.contains(".margin(.top, "), "no per-edge typed margin call site remains")
			#expect(text.contains(".margin(.bottom, "), "no per-edge typed margin call site remains")
			#expect(text.contains(".margin(0)"), "the zero-margin form is unused")
		}

		@Test("the census fires on a planted defect")
		func censusFires() {
			// the guard is worthless if it cannot see the thing it forbids, and a
			// length it cannot parse must not read as absent either.
			let planted: [(name: String, text: String)] = [
				(name: "Planted.swift", text: #"        .attribute("style", "margin-top:7px")"#),
				(name: "Planted.swift", text: #"        .attribute("style", "margin:1rem")"#),
				(name: "Clean.swift", text: #"        .margin(.top, .three)"#),
				(name: "Clean.swift", text: #"        .attribute("style", "padding:4px 2px 10px")"#),
				(name: "Comment.swift", text: #"        // .attribute("style", "margin-top:6px") is the old spelling"#),
			]
			let found = Self.sites(in: planted)
			#expect(found.count == 2, "expected the two real sites only, got: \(found.map(\.description))")
			#expect(found.contains { $0.style == "margin-top:7px" && $0.lengths == [7] })
			// `1rem` is unreadable to the census, which must surface it rather than
			// count it as a clean px site.
			#expect(found.contains { $0.style == "margin:1rem" && $0.unparsed == ["1rem"] })
		}
	}
}
