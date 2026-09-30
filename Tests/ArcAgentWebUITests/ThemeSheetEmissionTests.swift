import Foundation
import Testing

@testable import arc_agent_webui

/// The theme sheet is generated, not hand-written: `ArcThemeCatalog.stylesheet()` is the
/// emission of 27 providers through no-webui's `ThemeScope.attribute`.
///
/// These tests pin the properties a regression would silently break. A declaration that is
/// not a custom property is dropped by the browser without an error — which is exactly how
/// all 27 schemes once painted the base sheet's palette while the served bytes still looked
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

    private static var sheet: String { ArcThemeCatalog.stylesheet() }

    @Test("every declaration in the scheme sheet is a custom property")
    func everyDeclarationIsACustomProperty() {
        let sheet = Self.sheet
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
        let sheet = Self.sheet
        for entry in ArcThemeCatalog.entries {
            for mode in ["light", "dark", "system"] {
                let selector = ":root[data-scheme=\"\(entry.id)\"][data-theme=\"\(mode)\"]"
                let body = Self.blockBody(sheet, selector: selector)
                #expect(body != nil, "missing block for \(selector)")
                #expect(body?.contains("--color-bg:") == true, "\(selector) declares no --color-bg")
                #expect(body?.contains("--color-primary-solid:") == true, "\(selector) declares no --color-primary-solid")
            }
        }
    }

    @Test("arc's own properties ride the token they alias")
    func arcPropertiesAliasTheTokenVocabulary() {
        let body = Self.blockBody(
            Self.sheet,
            selector: ":root[data-scheme=\"poseidon\"][data-theme=\"dark\"]"
        )
        #expect(body?.contains("--color-bg: #0E1B22;") == true)
        #expect(body?.contains("--color-primary-solid: #4FC3E8;") == true)
        // the alias is an indirection, so the scheme states the value once…
        #expect(body?.contains("--bg: var(--color-bg);") == true)
        #expect(body?.contains("--accent: var(--color-primary-solid);") == true)
        // …and never a literal copy of it (which is what could drift)
        #expect(body?.contains("--bg: #0E1B22;") == false)
        #expect(body?.contains("--bg: #0D0D1A;") == false)
        // a property with no token equivalent stays literal
        #expect(body?.contains("--user-bubble:") == true)
    }

    @Test("the sheet covers every scheme in both palettes plus the system passes")
    func sheetCoversEverySchemeAndMode() {
        let sheet = Self.sheet
        // light + system + dark, plus one media-pass system block per scheme
        #expect(sheet.components(separatedBy: ":root[data-scheme=").count - 1 == ArcThemeCatalog.entries.count * 4)
        #expect(ArcThemeCatalog.entries.count == 27)
    }

    @Test("the catalog's identity is intact")
    func catalogIdentity() {
        let ids = ArcThemeCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate theme ids: \(ids)")
        #expect(ArcThemeCatalog.all.contains { $0.themeID == ArcThemeCatalog.defaultTheme.themeID })
        for entry in ArcThemeCatalog.entries {
            #expect(!entry.label.isEmpty, "\(entry.id) has no label")
            // [accent, dot, dot, dot] — arc's own shape; a swatch without an accent renders
            // a tile with no selection border.
            #expect(entry.swatch.count == 4, "\(entry.id) has \(entry.swatch.count) swatch colours")
            #expect(entry.swatch.allSatisfy { $0.hasPrefix("#") })
        }
    }
}