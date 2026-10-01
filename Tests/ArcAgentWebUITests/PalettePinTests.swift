import Foundation
import Testing

import ArcTheme
@testable import arc_agent_webui

/// The painted values, pinned to a checked-in fixture.
///
/// The sheet is about to change *how it is produced* — minified, then emitted through the
/// framework's asset toolkit — and the resolver diff that once proved value-identity lived in
/// `/tmp`. This is its permanent form: every pin below was extracted from the verified sheet,
/// and the test re-reads each one from the **product** bytes the server serves, so a minifier
/// or emitter that eats or rewrites a declaration fails here instead of on a page.
///
/// The pins are literal values, not aliases: `--bg` and `--text` are per-block `var(…)`
/// aliases, identical in every block, so the paint is pinned through the tokens those aliases
/// resolve to — with one alias pair per mode pinned as a spot-check that the indirection
/// survives too.
@Suite("Palette pins")
struct PalettePinTests {

    /// one pinned declaration: the block it lives in, and the value it must still hold.
    struct Pin: Decodable {
        let scheme: String
        let mode: String
        let property: String
        let value: String
    }

    enum FixtureError: Error {
        case missing
    }

    static func loadPins() throws -> [Pin] {
        guard
            let url = Bundle.module.url(
                forResource: "palette-pins", withExtension: "json", subdirectory: "Fixtures"
            )
        else { throw FixtureError.missing }
        return try JSONDecoder().decode([Pin].self, from: Data(contentsOf: url))
    }

    /// the declaration body of the block introduced by `selector`, first occurrence — the same
    /// reader the emission tests use.
    static func blockBody(_ css: String, selector: String) -> String? {
        guard let found = css.range(of: selector),
            let open = css[found.upperBound...].firstIndex(of: "{"),
            let close = css[open...].firstIndex(of: "}")
        else { return nil }
        return String(css[css.index(after: open)..<close])
    }

    /// the value `property` holds inside a block body, or nil when the block does not declare it.
    static func declaration(_ body: String, property: String) -> String? {
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(property + ":"), trimmed.hasSuffix(";") else { continue }
            return String(trimmed.dropFirst(property.count + 1).dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    @Test("the fixture covers every scheme and all three modes")
    func fixtureIsComplete() throws {
        let pins = try Self.loadPins()
        #expect(pins.count >= 70, "\(pins.count) pins is too few to be the full extraction")
        let schemes = Set(pins.map(\.scheme))
        #expect(
            schemes.count == 27,
            "every scheme has a dark background pinned; got \(schemes.count): \(schemes.sorted())"
        )
        #expect(Set(pins.map(\.mode)).isSuperset(of: ["light", "dark", "system"]))
    }

    @Test("every pinned declaration still holds in the served sheet")
    func paletteValuesMatchThePins() throws {
        let sheet = ThemeSheetAssets.sheet
        var failures: [String] = []
        for pin in try Self.loadPins() {
            let selector = ":root[data-scheme=\"\(pin.scheme)\"][data-theme=\"\(pin.mode)\"]"
            guard let body = Self.blockBody(sheet, selector: selector) else {
                failures.append("\(selector): block missing")
                continue
            }
            guard let value = Self.declaration(body, property: pin.property) else {
                failures.append("\(selector): \(pin.property) missing")
                continue
            }
            if value != pin.value {
                failures.append("\(selector) \(pin.property): \(value) != pinned \(pin.value)")
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(8).joined(separator: "; "))")
    }
}