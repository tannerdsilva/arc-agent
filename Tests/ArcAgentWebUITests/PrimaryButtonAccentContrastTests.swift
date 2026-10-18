import Foundation
import Testing

import ArcTheme
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The `.primary-btn` label contract (UX-01): every scheme x mode pair must clear
    /// WCAG AA (4.5:1) between `--accent` and `--accent-fg`.
    ///
    /// The old contract was a mode-swap — `--text` in light, `--bg` in dark — which
    /// assumed a bright accent in light mode. Graphite light pairs `--accent #303030`
    /// with label `#242424` at 1.18:1, so the label must be chosen per scheme against
    /// that scheme's accent. Each scheme states `--accent-fg` in its palette and dark
    /// palettes (a literal, like `--accent-soft`); this suite reads them back from the
    /// emitted sheet — the same bytes `stylesheets()` produces for the served product —
    /// and walks every scheme in both modes.
    @Suite("Primary button accent contrast", .serialized)
    struct PrimaryButtonAccentContrastTests {

        /// the declaration body of the block introduced by `selector`, first occurrence —
        /// the same reader the emission and palette-pin suites use.
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

        @Test("every scheme x mode primary-button label clears WCAG AA 4.5:1")
        func primaryButtonLabelClearsAA() {
            let sheet = ArcThemeCatalog.stylesheet()
            var rows: [String] = []
            var failures: [String] = []
            var minPair = ""
            var minRatio = Double.greatestFiniteMagnitude

            for entry in ArcThemeCatalog.entries {
                for mode in ["light", "dark"] {
                    let selector = ":root[data-scheme=\"\(entry.id)\"][data-theme=\"\(mode)\"]"
                    guard let body = Self.blockBody(sheet, selector: selector),
                        let accent = Self.declaration(body, property: "--color-primary-solid"),
                        let fg = Self.declaration(body, property: "--accent-fg"),
                        let ratio = Self.contrast(accent, fg)
                    else {
                        failures.append("\(selector): missing accent or accent-fg declaration")
                        continue
                    }
                    rows.append(String(format: "%-16@ %-6@ %@ on %@ = %.2f:1", entry.id, mode, fg, accent, ratio))
                    if ratio < minRatio {
                        minRatio = ratio
                        minPair = "\(entry.id)/\(mode) \(fg) on \(accent)"
                    }
                    if ratio < 4.5 {
                        failures.append("\(entry.id)/\(mode): \(fg) on \(accent) = \(String(format: "%.2f", ratio)):1")
                    }
                }
            }

            #expect(ArcThemeCatalog.entries.count == 27)
            #expect(rows.count == 54, "expected 54 pairs, got \(rows.count)")
            #expect(rows.contains { $0.hasPrefix("graphite") },
                    "Graphite light must be in the walked set")
            print("primary-btn contrast table:")
            print("scheme           mode   accent-fg on accent        ratio")
            for row in rows { print(row) }
            print("minimum: \(minPair) = \(String(format: "%.4f", minRatio)):1")
            #expect(failures.isEmpty,
                    "primary-btn label fails WCAG AA on \(failures.count) pair(s): \(failures.joined(separator: "; "))")
        }
    }
}
