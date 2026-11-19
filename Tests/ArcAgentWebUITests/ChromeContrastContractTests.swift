import Foundation
import Testing

import ArcTheme
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The chrome sheet's own contrast floor (UX pass): the app's secondary ink,
    /// the log-level labels, the status badge, the copy affordance and the active
    /// todo tab must all clear WCAG AA against the surfaces they are painted on.
    ///
    /// These were measured on the running UI, not guessed: `--muted` was `#8A8271`
    /// on `#FDFBF7` = **3.69:1**, and `.log-lvl` additionally multiplied it by
    /// `opacity: 0.85`, so a WARNING label painted at **2.09:1** and INFO at
    /// **3.66:1**. `.badge-green` pinned a bright mint (`#6fce8f`) that reads
    /// **1.83:1** on the light surface, and `.todo-tab-active` set `--accent` on an
    /// `--accent-soft` tint for **2.85:1**. Each assertion below pins the fix, and
    /// the ratio assertions read the palette the sheet actually ships.
    @Suite("Chrome contrast contract", .serialized)
    struct ChromeContrastContractTests {

        // MARK: - stylesheet readers (the same shape the palette suites use)

        /// the declaration body of the block introduced by `selector`, first occurrence.
        static func blockBody(_ css: String, selector: String) -> String? {
            guard let found = css.range(of: selector),
                let open = css[found.upperBound...].firstIndex(of: "{"),
                let close = css[open...].firstIndex(of: "}")
            else { return nil }
            return String(css[css.index(after: open)..<close])
        }

        /// the value `property` holds inside a block body, or nil when it does not declare it.
        static func declaration(_ body: String, property: String) -> String? {
            for line in body.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(property + ":"), trimmed.hasSuffix(";") else { continue }
                return String(trimmed.dropFirst(property.count + 1).dropLast())
                    .trimmingCharacters(in: .whitespaces)
            }
            return nil
        }

        /// resolve a `var(--x)` reference against a theme block's own declarations.
        static func resolve(_ value: String, in body: String) -> String? {
            var v = value.trimmingCharacters(in: .whitespaces)
            guard v.hasPrefix("var("), v.hasSuffix(")") else { return v }
            v = String(v.dropFirst(4).dropLast())
            if let comma = v.firstIndex(of: ",") { v = String(v[..<comma]) }
            return declaration(body, property: v.trimmingCharacters(in: .whitespaces))
        }

        /// WCAG 2.x relative luminance of a `#RRGGBB` colour.
        static func luminance(of hex: String) -> Double? {
            var h = hex.trimmingCharacters(in: .whitespaces)
            guard h.hasPrefix("#") else { return nil }
            h.removeFirst()
            guard h.count == 6, h.allSatisfy({ $0.isHexDigit }) else { return nil }
            let channels = [0, 2, 4].map {
                Double(Int(h.dropFirst($0).prefix(2), radix: 16) ?? 0) / 255.0
            }
            func linear(_ c: Double) -> Double {
                c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(channels[0]) + 0.7152 * linear(channels[1]) + 0.0722 * linear(channels[2])
        }

        /// WCAG 2.x contrast ratio between two `#RRGGBB` colours.
        static func contrast(_ a: String, _ b: String) -> Double? {
            guard let la = luminance(of: a), let lb = luminance(of: b) else { return nil }
            let hi = max(la, lb), lo = min(la, lb)
            return (hi + 0.05) / (lo + 0.05)
        }

        /// every occurrence of `selector`'s block body, in source order — a selector can
        /// appear twice (`system` has a literal block and one in the dark media pass).
        static func blockBodies(_ css: String, selector: String) -> [String] {
            var out: [String] = []
            var search = css.startIndex
            while let found = css.range(of: selector, range: search..<css.endIndex) {
                guard let open = css[found.upperBound...].firstIndex(of: "{"),
                    let close = css[open...].firstIndex(of: "}")
                else { break }
                out.append(String(css[css.index(after: open)..<close]))
                search = css.index(after: close)
            }
            return out
        }

        /// the literal a block paints for `property`: its own declaration, with one
        /// `var(--token)` indirection resolved against that same block. A scheme block
        /// states `--muted: var(--color-text-muted)`, so reading the declaration alone
        /// would compare two `var(…)` strings.
        static func painted(_ body: String, property: String) -> String? {
            guard let declared = declaration(body, property: property) else { return nil }
            return resolve(declared, in: body)
        }

        /// The default scheme's blocks that paint on a light surface: `light` and the
        /// literal `system` block (the dark media pass overrides `system`).
        ///
        /// Read from `ArcThemeCatalog.stylesheet()` — the paint a page is served — not
        /// from `Theme.css`, which now carries no palette of its own.
        static func lightSurfaceBlocks() -> [(selector: String, body: String)] {
            let sheet = ArcThemeCatalog.stylesheet()
            return [
                ":root[data-scheme=\"default\"][data-theme=\"light\"]",
                ":root[data-scheme=\"default\"][data-theme=\"system\"]",
            ].compactMap { selector in
                Self.blockBody(sheet, selector: selector).map { (selector, $0) }
            }
        }

        /// The default scheme's blocks that paint on a dark surface: `dark`, and the
        /// second `system` block — the one inside `@media (prefers-color-scheme: dark)`.
        static func darkSurfaceBlocks() -> [(selector: String, body: String)] {
            let sheet = ArcThemeCatalog.stylesheet()
            var blocks: [(selector: String, body: String)] = []
            let dark = ":root[data-scheme=\"default\"][data-theme=\"dark\"]"
            if let body = Self.blockBody(sheet, selector: dark) { blocks.append((dark, body)) }
            let system = ":root[data-scheme=\"default\"][data-theme=\"system\"]"
            let all = Self.blockBodies(sheet, selector: system)
            if all.count > 1 {
                blocks.append(("\(system) @media (prefers-color-scheme: dark)", all[1]))
            }
            return blocks
        }

        // MARK: - palette floors

        @Test("secondary ink clears AA on every light surface")
        func mutedClearsAA() {
            for (selector, body) in Self.lightSurfaceBlocks() {
                guard let muted = Self.painted(body, property: "--muted"),
                    let bg = Self.painted(body, property: "--bg"),
                    let surface = Self.painted(body, property: "--surface"),
                    let onBG = Self.contrast(muted, bg),
                    let onSurface = Self.contrast(muted, surface)
                else {
                    Issue.record("\(selector): missing --muted/--bg/--surface")
                    continue
                }
                #expect(onBG >= 4.5, "\(selector): --muted \(muted) on --bg \(bg) = \(String(format: "%.2f", onBG)):1")
                #expect(onSurface >= 4.5, "\(selector): --muted \(muted) on --surface \(surface) = \(String(format: "%.2f", onSurface)):1")
            }
        }

        @Test("secondary ink also clears AA in the dark palettes")
        func mutedClearsInDark() {
            for (selector, body) in Self.darkSurfaceBlocks() {
                guard let muted = Self.painted(body, property: "--muted"),
                    let bg = Self.painted(body, property: "--bg"),
                    let ratio = Self.contrast(muted, bg)
                else {
                    Issue.record("\(selector): missing --muted/--bg")
                    continue
                }
                #expect(ratio >= 4.5, "\(selector): --muted \(muted) on --bg \(bg) = \(String(format: "%.2f", ratio)):1")
            }
        }

        @Test("the warning label ink clears AA on every light surface")
        func warningStrongClearsAA() {
            for (selector, body) in Self.lightSurfaceBlocks() {
                guard let warning = Self.painted(body, property: "--warning-strong"),
                    let bg = Self.painted(body, property: "--bg"),
                    let ratio = Self.contrast(warning, bg)
                else {
                    Issue.record("\(selector): missing --warning-strong/--bg")
                    continue
                }
                #expect(ratio >= 4.5,
                        "\(selector): --warning-strong \(warning) on --bg \(bg) = \(String(format: "%.2f", ratio)):1 — the bright --warning is 2.54:1 and is for dots, not text")
            }
        }

        @Test("the success badge ink clears AA in the default scheme's blocks")
        func successBadgeClearsAA() {
            for (selector, body) in Self.lightSurfaceBlocks() + Self.darkSurfaceBlocks() {
                guard let success = Self.painted(body, property: "--success"),
                    let surface = Self.painted(body, property: "--surface"),
                    let ratio = Self.contrast(success, surface)
                else {
                    Issue.record("\(selector): missing --success/--surface")
                    continue
                }
                #expect(ratio >= 4.5, "\(selector): --success \(success) on --surface \(surface) = \(String(format: "%.2f", ratio)):1")
            }
        }

        /// Walks **every** scheme in the catalog in **both** modes and checks the pair the
        /// sheet actually paints a success hint with: `--success` on `--surface`.
        ///
        /// `successBadgeClearsAA` above is the literal spot-check: the default palette's
        /// `light`/`system`/`dark`/`system`-in-the-dark-pass blocks, resolved to the values
        /// they paint. It never measured a scheme that declares its own `colorSuccess`, and
        /// the browser gate has the same blind spot: it samples the active scheme. This test
        /// is the instrument that closes both.
        ///
        /// It reads the emitted sheet rather than the source structs, so it sees exactly
        /// what the browser sees: `ArcThemeCatalog.stylesheet()` renders each provider's
        /// `@Theme`-generated `theme` (base palette + this scheme's overrides, merged by
        /// `overlaying`) into `:root[data-scheme="<id>"][data-theme="<mode>"]`, declares
        /// `--success: var(--color-success)` / `--surface: var(--color-bg-raised)` there,
        /// and this test resolves those two indirections against that same block — the
        /// nearest declaration wins for the browser too.
        @Test("every scheme's success token clears AA on its own raised surface")
        func everySchemesSuccessClearsAA() {
            let sheet = ArcThemeCatalog.stylesheet()
            var rows: [String] = []
            var offenders: [(scheme: String, mode: String, success: String, surface: String, ratio: Double)] = []
            var minPair = ""
            var minRatio = Double.greatestFiniteMagnitude

            for entry in ArcThemeCatalog.entries {
                for mode in ["light", "dark"] {
                    let selector = ":root[data-scheme=\"\(entry.id)\"][data-theme=\"\(mode)\"]"
                    guard let body = Self.blockBody(sheet, selector: selector) else {
                        Issue.record("\(selector): no block in the emitted sheet")
                        continue
                    }
                    // the indirections the sheet declares, resolved in the block they are
                    // declared in — a `--success` that stopped meaning `colorSuccess` would
                    // make this test measure a pair the page does not paint.
                    guard let successAlias = Self.declaration(body, property: "--success"),
                        let surfaceAlias = Self.declaration(body, property: "--surface"),
                        successAlias == "var(--color-success)",
                        surfaceAlias == "var(--color-bg-raised)",
                        let success = Self.resolve(successAlias, in: body),
                        let surface = Self.resolve(surfaceAlias, in: body),
                        let ratio = Self.contrast(success, surface)
                    else {
                        let surfaceDecl = Self.declaration(body, property: "--surface") ?? "—"
                        let successDecl = Self.declaration(body, property: "--success") ?? "—"
                        Issue.record(
                            "\(selector): --success/--surface did not resolve to a #RRGGBB pair (surface \(surfaceDecl), success \(successDecl))")
                        continue
                    }
                    rows.append(String(format: "%-16@ %-6@ %@ on %@ = %.2f:1", entry.id, mode, success, surface, ratio))
                    if ratio < minRatio {
                        minRatio = ratio
                        minPair = "\(entry.id)/\(mode) \(success) on \(surface)"
                    }
                    if ratio < 4.5 {
                        offenders.append((entry.id, mode, success, surface, ratio))
                        Issue.record(
                            "\(entry.id)/\(mode): --success \(success) on --surface \(surface) = \(String(format: "%.2f", ratio)):1 — needs 4.5:1")
                    }
                }
            }

            print("success-on-surface contrast table:")
            print("scheme           mode   --success on --surface     ratio")
            for row in rows { print(row) }
            print("minimum: \(minPair) = \(String(format: "%.4f", minRatio)):1")

            #expect(rows.count == ArcThemeCatalog.entries.count * 2,
                    "walked \(rows.count) (scheme, mode) pairs of \(ArcThemeCatalog.entries.count * 2)")
            #expect(offenders.isEmpty,
                    "\(offenders.count) (scheme, mode) pair(s) paint --success below 4.5:1")
        }

        // MARK: - the rules that paint those surfaces

        @Test("log level labels stop alpha-dimming a semantic colour")
        func logLevelsAreNotDimmed() {
            let css = Theme.css
            guard let base = css.range(of: ".log-line .log-lvl {"),
                let close = css[base.upperBound...].firstIndex(of: "}")
            else {
                Issue.record("the .log-lvl rule is missing")
                return
            }
            let body = String(css[base.upperBound..<close])
            #expect(!body.contains("opacity"),
                    "`opacity` multiplies an already-marginal label toward the background: WARNING painted at 2.09:1 while its palette colour was 2.54:1")
            #expect(css.contains(".log-line.lvl-warn .log-lvl { color: var(--warning-strong); }"),
                    "the warning label must use the text-grade amber, not the dot-grade --warning")
        }

        @Test("the status badge uses the theme's success colour, not a mint literal")
        func badgeUsesSuccessToken() {
            let css = Theme.css
            guard let body = Self.blockBody(css, selector: ".badge-green ") else {
                Issue.record("the .badge-green rule is missing")
                return
            }
            #expect(body.contains("color: var(--success)"),
                    "a literal mint (#6fce8f) reads 1.83:1 on the light surface; the badge must follow the palette")
            #expect(!body.contains("#6fce8f"), "no mint literal survives")
        }

        @Test("the copy affordance is not dimmed, and hover darkens it")
        func copyCodeIsNotDimmed() {
            let css = Theme.css
            guard let body = Self.blockBody(css, selector: ".copy-code ") else {
                Issue.record("the .copy-code rule is missing")
                return
            }
            #expect(!body.contains("opacity"),
                    "an 0.85 alpha over --muted painted the Copy label at 3.96:1")
            #expect(css.contains(".copy-code:hover { color: var(--text); }"),
                    "hover must provide the visible delta now that the base is at full opacity")
        }

        @Test("the todo empty-state hint is not alpha-dimmed")
        func todoEmptyHintIsNotDimmed() {
            let css = Theme.css
            guard let body = Self.blockBody(css, selector: ".todo-empty small ") else {
                Issue.record("the .todo-empty small rule is missing")
                return
            }
            #expect(!body.contains("opacity"),
                    "the hint inherits --muted from .todo-empty; `opacity: .7` painted it at 2.95:1")
        }

        @Test("the active todo tab paints readable ink on its tint")
        func todoTabActiveInk() {
            let css = Theme.css
            guard let body = Self.blockBody(css, selector: ".todo-tab-active ") else {
                Issue.record("the .todo-tab-active rule is missing")
                return
            }
            guard let ink = Self.declaration(body, property: "color") else {
                Issue.record("the active tab declares no colour")
                return
            }
            #expect(ink == "var(--text)",
                    "--accent text on the --accent-soft tint measured 2.85:1; --text is the tab's own hover ink")
        }
    }
}
