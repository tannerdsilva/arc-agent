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

        /// every theme block that paints on a light surface.
        static let lightThemes = [
            ":root[data-theme=\"light\"]",
            ":root[data-theme=\"system\"]",
        ]
        /// the literal dark palette blocks.
        static let darkThemes = [
            ":root[data-theme=\"dark\"]",
        ]

        // MARK: - palette floors

        @Test("secondary ink clears AA on every light surface")
        func mutedClearsAA() {
            let css = Theme.css
            for selector in Self.lightThemes {
                guard let body = Self.blockBody(css, selector: selector),
                    let muted = Self.declaration(body, property: "--muted"),
                    let bg = Self.declaration(body, property: "--bg"),
                    let surface = Self.declaration(body, property: "--surface"),
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
            let css = Theme.css
            for selector in Self.darkThemes {
                guard let body = Self.blockBody(css, selector: selector),
                    let muted = Self.declaration(body, property: "--muted"),
                    let bg = Self.declaration(body, property: "--bg"),
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
            let css = Theme.css
            for selector in Self.lightThemes {
                guard let body = Self.blockBody(css, selector: selector),
                    let warning = Self.declaration(body, property: "--warning-strong"),
                    let bg = Self.declaration(body, property: "--bg"),
                    let ratio = Self.contrast(warning, bg)
                else {
                    Issue.record("\(selector): missing --warning-strong/--bg")
                    continue
                }
                #expect(ratio >= 4.5,
                        "\(selector): --warning-strong \(warning) on --bg \(bg) = \(String(format: "%.2f", ratio)):1 — the bright --warning is 2.54:1 and is for dots, not text")
            }
        }

        @Test("the success badge ink clears AA in every theme that declares it")
        func successBadgeClearsAA() {
            let css = Theme.css
            for selector in Self.lightThemes + Self.darkThemes {
                guard let body = Self.blockBody(css, selector: selector),
                    let success = Self.declaration(body, property: "--success"),
                    let surface = Self.declaration(body, property: "--surface"),
                    let ratio = Self.contrast(success, surface)
                else {
                    Issue.record("\(selector): missing --success/--surface")
                    continue
                }
                #expect(ratio >= 4.5, "\(selector): --success \(success) on --surface \(surface) = \(String(format: "%.2f", ratio)):1")
            }
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
