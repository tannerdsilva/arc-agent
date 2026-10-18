import Foundation
import Testing
@testable import ArcAgentCore

extension ArcCoreTestRoot {

	/// I1's static half — no source under `Sources/` can detach.
	///
	/// The compile-time half is the spawn surface itself: arc's callers cannot
	/// express a placement, and ``SubprocessRunner``/``ACPClient`` hardcode
	/// `.own`, so `.detached` is unrepresentable in arc's API. This is the
	/// static half, and it is a *scan* rather than a grep for a reason: the
	/// house scanners read code, not prose. A doc comment that discusses
	/// detachment (this change adds two) is not a call site, and neither is a
	/// string literal that happens to spell it.
	@Suite("Process detachment guard", .serialized)
	struct ProcessDetachmentGuardTests {

		// MARK: - the scanner

		/// Source text with comments removed and string literals blanked, so a
		/// scan can only see code.
		///
		/// Comments go first (line-based, the house pattern), then strings: a
		/// quote that is still open at a newline is closed there, so one odd
		/// literal cannot swallow the rest of a file.
		static func codeOnly(_ text: String) -> String {
			maskStrings(stripComments(text))
		}

		static func stripComments(_ text: String) -> String {
			text
				.components(separatedBy: "\n")
				.map { line -> String in
					let trimmed = line.trimmingCharacters(in: .whitespaces)
					if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
						return ""
					}
					guard let cut = line.range(of: "//") else { return line }
					return String(line[line.startIndex..<cut.lowerBound])
				}
				.joined(separator: "\n")
		}

		static func maskStrings(_ text: String) -> String {
			var output = ""
			var inString = false
			var escaped = false
			for character in text {
				if character == "\n" {
					// bound the damage of an unterminated literal.
					inString = false
					escaped = false
					output.append(character)
					continue
				}
				if inString {
					if escaped {
						escaped = false
					} else if character == "\\" {
						escaped = true
					} else if character == "\"" {
						inString = false
						output.append(character)
						continue
					}
					output.append(" ")
					continue
				}
				if character == "\"" {
					inString = true
				}
				output.append(character)
			}
			return output
		}

		/// The offending lines a scan of `code` finds: a `.detached` placement,
		/// or a `processGroup:` argument that is anything but `.own`.
		static func violations(in code: String) -> [String] {
			var found: [String] = []
			for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
				let text = String(line)
				if text.contains(".detached") {
					found.append(text.trimmingCharacters(in: .whitespaces))
					continue
				}
				var remainder = text[...]
				while let range = remainder.range(of: "processGroup:") {
					let argument = remainder[range.upperBound...].drop { $0 == " " || $0 == "\t" }
					if !argument.hasPrefix(".own") {
						found.append(text.trimmingCharacters(in: .whitespaces))
						break
					}
					remainder = remainder[range.upperBound...]
				}
			}
			return found
		}

		private static func swiftFiles(under root: String) -> [String] {
			guard let walk = FileManager.default.enumerator(atPath: root) else { return [] }
			return walk.compactMap { entry in
				guard let entry = entry as? String, entry.hasSuffix(".swift") else { return nil }
				return "\(root)/\(entry)"
			}
		}

		private static func sourcesRoot() -> String {
			URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()
				.deletingLastPathComponent()
				.deletingLastPathComponent()
				.appendingPathComponent("Sources")
				.path
		}

		// MARK: - the pins

		/// the scanners must bite on code and stay quiet on prose — otherwise a
		/// green run proves nothing.
		@Test("the scanners bite on code, and not on prose or literals")
		func scannerSelfCheck() {
			let code = "        let c = ChildProcess(cmd, processGroup: .detached, dataChannels: [:])"
			let otherPlacement = "        let c = ChildProcess(cmd, processGroup: .inherited)"
			let owned = "        let c = ChildProcess(cmd, processGroup: .own, dataChannels: [:])"
			let prose = "        /// never request `.detached`: it is unreachable by design"
			let literal = "        let name = \".detached\""

			#expect(!Self.violations(in: Self.codeOnly(code)).isEmpty,
				"a `.detached` placement in code must fire")
			#expect(!Self.violations(in: Self.codeOnly(otherPlacement)).isEmpty,
				"a placement that is not `.own` must fire")
			#expect(Self.violations(in: Self.codeOnly(owned)).isEmpty,
				"`.own` is the placement arc asks for everywhere")
			#expect(Self.violations(in: Self.codeOnly(prose)).isEmpty,
				"prose that names `.detached` must be stripped before the scan")
			#expect(Self.violations(in: Self.codeOnly(literal)).isEmpty,
				"a string literal is not a call site")
		}

		@Test("no source under Sources/ detaches, and every spawn asks for .own")
		func sourcesDoNotDetach() throws {
			let root = Self.sourcesRoot()
			let files = Self.swiftFiles(under: root)
			#expect(files.count > 100, "the scan must actually walk arc's sources")

			var offenders: [String] = []
			for file in files {
				guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
				for violation in Self.violations(in: Self.codeOnly(text)) {
					offenders.append("\(file): \(violation)")
				}
			}
			#expect(offenders.isEmpty, "detached/foreign placements found:\n\(offenders.joined(separator: "\n"))")
		}

		// MARK: - the spawn census

		private static func filesContaining(_ token: String, in files: [String], under root: String) -> [String] {
			var found: [String] = []
			for file in files {
				guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
				if codeOnly(text).contains(token) {
					found.append(file.replacingOccurrences(of: root + "/", with: ""))
				}
			}
			return found.sorted()
		}

		/// From the SwiftSlash surface, so `ChildProcess(` does not read as a
		/// Foundation `Process()`.
		private static func filesConstructingFoundationProcess(in files: [String], under root: String) -> [String] {
			var found: [String] = []
			for file in files {
				guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
				let code = codeOnly(text)
					.replacingOccurrences(of: "ChildProcess(", with: "SwiftSlashSpawn(")
				if code.contains("Process()") {
					found.append(file.replacingOccurrences(of: root + "/", with: ""))
				}
			}
			return found.sorted()
		}

		/// Every spawn site in the tree, pinned.
		///
		/// A placement is only expressible where a spawner can express one, so the
		/// set of spawners IS the contract's blast radius — and a census is what
		/// keeps that set from growing quietly.
		///
		/// - `ChildProcess(` carries the placement. The audited pair hardcode
		///   `.own`; `ArcSubprocessFixture` is a test executable that ships in no
		///   product and deliberately asks for nothing, so the inherited cascade has
		///   a subject.
		/// - `Process()` cannot express a placement at all — a Foundation child
		///   joins arc's OWN group. That is a documented carve-out (see the note in
		///   `ProcessRegistry`), not something this test discovered: three
		///   short-lived helpers (`ps`, `kill`, a hook interpreter) plus three
		///   long-lived children that predate the contract. Named here so the debt
		///   stays visible and a seventh site has to be argued for rather than
		///   slipped in.
		@Test("the spawn census is exactly the audited set")
		func spawnCensusIsAudited() {
			let root = Self.sourcesRoot()
			let files = Self.swiftFiles(under: root)

			let swiftSlash = Self.filesContaining("ChildProcess(", in: files, under: root)
			#expect(swiftSlash == [
				"ArcAgentCore/LLM/Adapters/ACPClient.swift",
				"ArcAgentCore/Support/SubprocessRunner.swift",
				"ArcSubprocessFixture/ArcSubprocessFixture.swift",
			], "SwiftSlash spawn sites changed: \(swiftSlash.joined(separator: ", "))")

			let foundation = Self.filesConstructingFoundationProcess(in: files, under: root)
			#expect(foundation == [
				"ArcAgentCore/Hooks/HookBus.swift",
				"ArcAgentCore/Process/ProcessRegistry.swift",
				"ArcAgentCore/Process/ProcessWatch.swift",
				"ArcAgentCore/Tools/ComputerUseTool.swift",
				"ArcWebUI/SidecarPlugin.swift",
			], "Foundation spawn sites changed — such a child joins arc's own group and cannot be torn down as a group: \(foundation.joined(separator: ", "))")
		}
	}
}