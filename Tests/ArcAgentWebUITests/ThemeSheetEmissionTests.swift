import Foundation
import Testing

@testable import arc_agent_webui

/// The theme sheet is generated, not hand-written: `Theme.schemeCSS` is the emission of 27
/// schemes through no-webui's `ThemeScope.attribute`.
///
/// These tests pin the properties a regression would silently break. A declaration that is
/// not a custom property is dropped by the browser without an error — which is exactly how
/// all 27 schemes painted the base sheet's palette while the served bytes still looked
/// plausible (`bg: #FDFBF7;` instead of `--bg: #FDFBF7;`).
@Suite("Theme sheet emission")
struct ThemeSheetEmissionTests {

    /// no-webui's emission also declares standard properties that belong in a theme block:
    /// `color-scheme` tells the browser's own chrome which way the page faces. Anything else
    /// unprefixed is a declaration the browser drops.
    private static let frameworkStandardProperties: Set<String> = ["color-scheme"]

    /// The property name of a `name: value;` declaration.
    private static func propertyName(_ declaration: String) -> String {
        String(declaration.trimmingCharacters(in: .whitespaces).prefix(while: { $0 != ":" }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// A line that declares something inside a rule block: `name: value;`.
    private static func declarationLines(_ css: String) -> [String] {
        css.split(separator: "\n").map(String.init).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.contains(":") && t.hasSuffix(";")
        }
    }

    /// The declaration body of the block introduced by `selector`, or nil when absent.
    private static func blockBody(_ css: String, selector: String) -> String? {
        guard let found = css.range(of: selector),
            let open = css[found.upperBound...].firstIndex(of: "{"),
            let close = css[open...].firstIndex(of: "}")
        else { return nil }
        return String(css[css.index(after: open)..<close])
    }

    @Test("every declaration in the scheme sheet is a custom property")
    func everyDeclarationIsACustomProperty() {
        let sheet = Theme.schemeCSS
        #expect(!sheet.isEmpty)
        let bare = Self.declarationLines(sheet).filter { line in
            let name = Self.propertyName(line)
            return !name.hasPrefix("--") && !Self.frameworkStandardProperties.contains(name)
        }
        #expect(
            bare.isEmpty,
            "the browser drops these declarations, leaving the base palette in place: \(Set(bare.map(Self.propertyName)).sorted())"
        )
    }

    @Test("every scheme declares its palette in light, dark and system modes")
    func everySchemeDeclaresItsPalette() {
        let sheet = Theme.schemeCSS
        for scheme in ColorScheme.all {
            for mode in ["light", "dark", "system"] {
                let selector = ":root[data-scheme=\"\(scheme.id)\"][data-theme=\"\(mode)\"]"
                let body = Self.blockBody(sheet, selector: selector)
                #expect(body != nil, "missing block for \(selector)")
                #expect(body?.contains("--bg:") == true, "\(selector) declares no --bg")
                #expect(body?.contains("--accent:") == true, "\(selector) declares no --accent")
            }
        }
    }

    @Test("a scheme's values land in that scheme's block")
    func schemeValuesLandInTheirOwnBlock() {
        let poseidonDark = Self.blockBody(
            Theme.schemeCSS,
            selector: ":root[data-scheme=\"poseidon\"][data-theme=\"dark\"]"
        )
        #expect(poseidonDark?.contains("--bg: #0E1B22;") == true)
        #expect(poseidonDark?.contains("--accent: #4FC3E8;") == true)

        // and they are not the base sheet's values, which every scheme painted before the fix
        #expect(poseidonDark?.contains("--bg: #0D0D1A;") == false)
    }

    @Test("the sheet covers every scheme in both palettes plus the system passes")
    func sheetCoversEverySchemeAndMode() {
        let sheet = Theme.schemeCSS
        // light + system + dark, plus one media-pass system block per scheme
        #expect(sheet.components(separatedBy: ":root[data-scheme=").count - 1 == ColorScheme.all.count * 4)
        #expect(ColorScheme.all.count == 27)
        #expect(Set(ColorScheme.all.map(\.id)).count == ColorScheme.all.count)
    }
}