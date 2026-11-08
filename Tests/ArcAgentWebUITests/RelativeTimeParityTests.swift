import Foundation
import Testing

@testable import ArcWebUI

// the relative-time ladder is written twice, in two languages: `AppState`'s
// `relTimeLabel` paints the first frame server-side, and `overlay.js`'s
// `relLabel` repaints the `<span data-reltime>` labels in place every 60 s
// without a round-trip. neither can own the other — the client cannot render
// the initial HTML and the server cannot run a 60 s timer in the page — so the
// duplication is permanent, and duplication that cannot be deleted can only be
// pinned.
//
// this suite is a DRIFT ALARM, not a refactor. it does not make the two ladders
// share an implementation, and it is not permission to start "unifying" them:
// it fails the day either ladder's buckets or format change without the other,
// which is the only failure mode that matters and the one nothing else in this
// tree can see.
//
// it also cannot be deleted as "already covered by the JS test". the two sides
// run in different runtimes and neither test can execute the other's code:
// `Scripts/relative-time-parity.mjs` extracts `relLabel` from `overlay.js` and
// evaluates it under node with a frozen clock, and this suite calls
// `AppState.relTimeLabel` with an injected `now`. the shared artifact is
// `Fixtures/relative-time-golden.tsv`, whose `expected` column was derived by
// hand from the documented ladder rather than from either implementation — so
// each side is asserted against an independent literal, and a single ladder
// drifting cannot hide behind the other agreeing with it.
//
// `relTimeLabel`'s `now:` parameter exists for this: it defaults to `Date()`,
// so the production call site and its label format are untouched, and a test
// can ask the ladder what it would say at a fixed instant.
extension ArcWebUITestRoot {

    @Suite("Relative time parity", .serialized)
    struct RelativeTimeParityTests {

        /// the golden's location on disk, matching `RenderParity`'s pattern: the
        /// working directory first (so a row can be read and fixed in place), then
        /// the bundled copy for runners that do not vend the package root.
        private static let fixtureRelativePath = "Tests/ArcAgentWebUITests/Fixtures/relative-time-golden.tsv"
        private static let fixtureName = "relative-time-golden"
        private static let fixtureSubdirectory = "Fixtures"

        /// the floor the table must not fall below. a golden that lost its rows
        /// would otherwise assert nothing and report green — the same vacuous pass
        /// the node harness refuses by printing its row count.
        private static let minimumRows = 12

        struct Row: CustomStringConvertible {
            let line: Int
            let nowMs: Int
            let thenMs: Int
            let expected: String

            var description: String {
                "row \(line): now_ms \(nowMs) then_ms \(thenMs) expected \"\(expected)\""
            }
        }

        enum FixtureError: Error, CustomStringConvertible {
            case unreadable(String)
            case malformed(line: Int, detail: String)

            var description: String {
                switch self {
                case .unreadable(let path):
                    "relative-time golden not found: looked for \(path), then the bundled Fixtures copy"
                case .malformed(let line, let detail):
                    "relative-time golden row \(line): \(detail)"
                }
            }
        }

        private static func fixtureText() throws -> String {
            let onDisk = URL(fileURLWithPath: fixtureRelativePath)
            if let data = try? Data(contentsOf: onDisk), let text = String(data: data, encoding: .utf8) {
                return text
            }
            if let url = Bundle.module.url(forResource: fixtureName, withExtension: "tsv",
                                           subdirectory: fixtureSubdirectory),
               let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            throw FixtureError.unreadable(fixtureRelativePath)
        }

        /// `#` comments and blank lines are skipped so the table can carry the
        /// wall-clock caveat next to the data it constrains.
        static func rows() throws -> [Row] {
            var rows: [Row] = []
            for (index, raw) in try fixtureText().split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = index + 1
                let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
                if text.trimmingCharacters(in: .whitespaces).isEmpty || text.hasPrefix("#") { continue }
                let fields = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                // the column header, not a row.
                if fields.count == 3, fields[0] == "now_ms", fields[1] == "then_ms" { continue }
                guard fields.count == 3 else {
                    throw FixtureError.malformed(line: line, detail: "expected 3 tab-separated columns, got \(fields.count)")
                }
                guard let nowMs = Int(fields[0]), let thenMs = Int(fields[1]) else {
                    throw FixtureError.malformed(line: line, detail: "non-integer epoch column")
                }
                guard !fields[2].isEmpty else {
                    throw FixtureError.malformed(line: line, detail: "empty expected label")
                }
                rows.append(Row(line: line, nowMs: nowMs, thenMs: thenMs, expected: fields[2]))
            }
            return rows
        }

        @Test("every golden row matches the Swift ladder")
        func swiftLadderMatchesGoldenTable() async throws {
            let rows = try Self.rows()
            #expect(rows.count >= Self.minimumRows,
                    "the golden table has \(rows.count) rows; it must keep covering every bucket (>= \(Self.minimumRows)) or it stops being a pin")

            let app = AppState(renderFixture: .init())
            var drifted = 0
            for row in rows {
                let then = Date(timeIntervalSince1970: TimeInterval(row.thenMs) / 1000)
                let now = Date(timeIntervalSince1970: TimeInterval(row.nowMs) / 1000)
                let got = await app.relTimeLabel(then, now: now)
                if got != row.expected { drifted += 1 }
                #expect(got == row.expected,
                        "\(row) — the Swift ladder returned \"\(got)\"; either the ladder moved or the golden is wrong, and the JS ladder is pinned to the same literal")
            }
            #expect(drifted == 0, "\(drifted) of \(rows.count) golden rows drifted from the Swift ladder")
        }
    }
}
