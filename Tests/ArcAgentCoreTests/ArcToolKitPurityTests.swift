import Foundation
import Testing

// MARK: - ArcToolKit purity

extension ArcCoreTestRoot {

    /// `ArcToolKit` declares no dependencies, which makes everything outside the
    /// standard library unreachable from it — but only for symbols the compiler
    /// has to resolve. A bare `import Foundation` in a file that names nothing
    /// from Foundation still compiles (measured, GROUNDZERO D26), and with it the
    /// whole of Foundation becomes reachable again from the target whose
    /// emptiness *is* the guarantee.
    ///
    /// These tests are the other half of §6: they read the target's own source
    /// and refuse the import and the three I/O spellings that would restore a
    /// capability the split exists to remove. The scan is deliberately textual —
    /// a syntax-aware check would need a parser, i.e. a dependency — so a new
    /// spelling of I/O is a review-visible edit to this list.
    @Suite("ArcToolKit purity")
    struct ArcToolKitPurityTests {

        /// One line of one kit source, carrying the path a failure must name.
        private struct Line {
            let path: String
            let text: String
        }

        private static let importKeyword = "import"
        private static let testableAttribute = "@testable"

        /// Every `.swift` file under `Sources/ArcToolKit/`, line by line.
        ///
        /// The package root is found by climbing from this file until a
        /// directory holds `Package.swift`, so the checkout can live anywhere
        /// and no absolute path is baked in.
        private static func kitLines() throws -> [Line] {
            var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
                let parent = root.deletingLastPathComponent()
                try #require(parent.path != root.path, "no Package.swift above this test file")
                root = parent
            }

            let kit = root.appendingPathComponent("Sources/ArcToolKit")
            let walker = try #require(
                FileManager.default.enumerator(at: kit, includingPropertiesForKeys: nil),
                "expected the kit's sources beside this test file at \(kit.path)"
            )
            var files: [URL] = []
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(url)
            }
            files.sort { $0.path < $1.path }

            // An empty or moved directory would make every assertion below pass
            // vacuously, which is the one way this test can lie.
            try #require(files.count >= 4, "expected the kit's sources, found \(files.count) file(s)")

            return try files.flatMap { url -> [Line] in
                let text = try String(contentsOf: url, encoding: .utf8)
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                return text.components(separatedBy: .newlines).map { Line(path: path, text: $0) }
            }
        }

        /// A failure message that names the file and the offending line.
        private static func describe(_ lines: [Line]) -> String {
            lines
                .map { "\($0.path): \($0.text.trimmingCharacters(in: .whitespaces))" }
                .joined(separator: " | ")
        }

        /// No line may import anything at all — Foundation least of all, and
        /// `@testable import` counts as an import.
        @Test("no line imports anything")
        func noImports() throws {
            let offenders = try Self.kitLines().filter { line in
                var probe = line.text.trimmingCharacters(in: .whitespaces)
                if probe.hasPrefix(Self.testableAttribute) {
                    probe = String(probe.dropFirst(Self.testableAttribute.count))
                        .trimmingCharacters(in: .whitespaces)
                }
                guard probe.hasPrefix(Self.importKeyword) else { return false }
                return probe.dropFirst(Self.importKeyword.count).first?.isWhitespace ?? false
            }
            #expect(offenders.isEmpty, "imports in ArcToolKit: \(Self.describe(offenders))")
        }

        /// The regex engine lives in Foundation; a kit file naming it has
        /// re-imported Foundation under another spelling.
        @Test("no NSRegularExpression")
        func noRegularExpression() throws {
            let offenders = try Self.kitLines().filter { $0.text.contains("NSRegularExpression") }
            #expect(offenders.isEmpty, "NSRegularExpression in ArcToolKit: \(Self.describe(offenders))")
        }

        /// The filesystem is Foundation's; authority values must not be able to
        /// resolve one.
        @Test("no FileManager")
        func noFileManager() throws {
            let offenders = try Self.kitLines().filter { $0.text.contains("FileManager") }
            #expect(offenders.isEmpty, "FileManager in ArcToolKit: \(Self.describe(offenders))")
        }

        /// Same capability, spelled as a URL: constructing a file URL is how a
        /// path becomes something a caller can open.
        @Test("no URL(fileURLWithPath")
        func noFilePathURLs() throws {
            let offenders = try Self.kitLines().filter { $0.text.contains("URL(fileURLWithPath") }
            #expect(offenders.isEmpty, "URL(fileURLWithPath in ArcToolKit: \(Self.describe(offenders))")
        }
    }
}
