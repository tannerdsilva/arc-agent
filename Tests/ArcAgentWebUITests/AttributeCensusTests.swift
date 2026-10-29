import Foundation
import Testing

@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The attribute census: arc's web UI contributes every `aria-*`, `data-*` and
    /// `data-webui-key` through the typed vocabulary, never through a hand-written
    /// `.attribute("aria-…", …)` string.
    ///
    /// The reason this is a test and not a convention: a hand-written attribute is a
    /// *string*, so nothing checks that the name is spelled correctly, that the value is
    /// escaped, or that an inactive state omits the attribute rather than emitting an
    /// empty one. `aria-current=""` shipped in the tools panel for exactly that reason
    /// — an empty token that matches nothing, invisible to every reader of the code.
    /// The typed modifiers cannot express it, which is the point.
    @Suite("Attribute census", .serialized)
    struct AttributeCensusTests {

        /// one violation per hand-written attribute, as `file:line  snippet`.
        ///
        /// pure so the pin can be shown to fire on a planted defect without editing
        /// the sources it guards.
        static func violations(in files: [(name: String, text: String)]) -> [String] {
            var found: [String] = []
            for file in files {
                for (index, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // a comment may quote the pattern; only code counts.
                    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                    for prefix in [".attribute(\"aria-", ".attribute(\"data-",
                                   ".attribute(\"hidden\"", ".attribute(\"checked\"",
                                   ".attribute(\"disabled\"", ".attribute(\"selected\"",
                                   ".attribute(\"required\"", ".attribute(\"readonly\""] {
                        guard let range = trimmed.range(of: prefix) else { continue }
                        let snippet = String(trimmed[range.lowerBound...].prefix(60))
                        found.append("\(file.name):\(index + 1)  \(snippet)")
                    }
                }
            }
            return found
        }

        /// the web UI sources, read from disk beside this test file.
        private static func webUISources() throws -> [(name: String, text: String)] {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ArcAgentWebUITests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // package root
                .appendingPathComponent("Sources/ArcWebUI")
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".swift") }
                .sorted()
            // an empty or moved directory would make every pin below pass vacuously.
            try #require(names.count > 10, "expected the web UI sources beside the tests, found \(names.count)")
            return try names.map { name in
                (name, try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))
            }
        }

        @Test("no hand-written aria-* attribute survives in the web UI")
        func noHandWrittenAria() throws {
            let offenders = Self.violations(in: try Self.webUISources())
                .filter { $0.contains("\"aria-") }
            #expect(offenders.isEmpty, "hand-written aria attributes: \(offenders)")
        }

        @Test("no hand-written boolean attribute survives in the web UI")
        func noHandWrittenBoolean() throws {
            let booleanNames = ["hidden", "checked", "disabled", "selected", "required", "readonly"]
            let offenders = Self.violations(in: try Self.webUISources())
                .filter { line in booleanNames.contains { line.contains("\"\($0)\"") } }
            #expect(offenders.isEmpty, "hand-written boolean attributes: \(offenders)")
        }

        @Test("no hand-written data-* attribute survives in the web UI")
        func noHandWrittenData() throws {
            let offenders = Self.violations(in: try Self.webUISources())
                .filter { $0.contains("\"data-") }
            #expect(offenders.isEmpty, "hand-written data attributes: \(offenders)")
        }

        @Test("the census fires on a planted defect")
        func censusFires() {
            // the guard is worthless if it cannot see the thing it forbids.
            let planted = [
                (name: "Planted.swift", text: "        .attribute(\"aria-current\", active ? \"true\" : \"\")"),
                (name: "Planted.swift", text: "        .attribute(\"data-sid\", s.id)"),
                (name: "Clean.swift", text: "        .aria(.current(.yes))"),
                (name: "Comment.swift", text: "            // .attribute(\"aria-hidden\", \"true\") is the old spelling"),
            ]
            let found = Self.violations(in: planted)
            #expect(found.count == 2, "expected the two real sites only, got: \(found)")
            #expect(found.contains { $0.contains("aria-current") })
            #expect(found.contains { $0.contains("data-sid") })
        }

        @Test("the typed vocabulary is actually used, so the census tests a live surface")
        func typedVocabularyIsUsed() throws {
            let text = try Self.webUISources().map(\.text).joined()
            // if the modifiers were unused, an empty-file census would pass forever.
            #expect(text.contains(".aria("), "no typed aria call site remains")
            #expect(text.contains(".data("), "no typed data call site remains")
            #expect(text.contains(".webuiKey("), "no typed webuiKey call site remains")
        }
    }
}