import Foundation
import Testing

import ArcTheme
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// Link legibility: every `--link` the sheet emits must clear WCAG AA (4.5:1) against
    /// the `--bg` of the same scheme×mode block it is painted in.
    ///
    /// This is the instrument for a defect that is invisible to every other gate: the
    /// token resolves (so `SheetTokenResolutionTests` is green), the palette is coherent
    /// (so the scheme matrix is green), and the contrast sampler measures only the
    /// transcript it happens to open — a chat with no anchor never exercises a link and
    /// the row passes vacuously. The failure is a *pairwise* property of two tokens in
    /// the same block, and the only honest place to state it is against the served bytes.
    ///
    /// Three facts make this test worth its cost:
    ///
    ///  * it reads `ThemeSheetAssets.text`, the minified, stamped sheet the daemon
    ///    serves — not the catalog source. A minifier that ate `--link`, a provider that
    ///    stopped emitting a scheme, or a base-palette edit all show up here.
    ///  * it resolves `--bg` through its alias (`--bg: var(--color-bg)`), because that is
    ///    what the browser does; comparing against a hardcoded white would have measured
    ///    the wrong surface for 26 of the 27 schemes (and hid four dark-mode failures).
    ///  * it walks all four served blocks per scheme — `light`, `system`, `dark`, and the
    ///    `system` block inside `@media (prefers-color-scheme: dark)` — so a scheme cannot
    ///    pass by emitting a link only where the check is not looking. `system` paints the
    ///    light palette in a light preference and the dark palette in a dark one; both
    ///    spellings are asserted, which is why one bad palette value produces two lines.
    @Suite("Link contrast", .serialized)
    struct LinkContrastTests {

        /// 4.5:1 — WCAG 2.x AA for normal text. Links are body-size inline text, not
        /// large text, so the large-text 3:1 allowance does not apply.
        static let required: Double = 4.5

        // MARK: - colour

        /// A resolved colour, kept as the token declared it so a failure can print the
        /// exact bytes an author typed.
        struct Colour: CustomStringConvertible {
            let hex: String
            let rgb: (r: Double, g: Double, b: Double)

            var description: String { hex }

            /// `#rgb` / `#rrggbb` only. Everything else (an `rgba()` tint, a gradient, a
            /// second indirection this reader does not follow) is *unmeasurable*, and an
            /// unmeasurable link is a failure of the instrument, never a pass.
            init?(_ raw: String) {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("#") else { return nil }
                var digits = String(text.dropFirst())
                if digits.count == 3 {
                    digits = digits.map { "\($0)\($0)" }.joined()
                }
                guard digits.count == 6 else { return nil }
                var channels: [Double] = []
                var index = digits.startIndex
                for _ in 0..<3 {
                    let end = digits.index(index, offsetBy: 2)
                    guard let byte = UInt8(digits[index..<end], radix: 16) else { return nil }
                    channels.append(Double(byte) / 255)
                    index = end
                }
                self.hex = text.uppercased()
                self.rgb = (channels[0], channels[1], channels[2])
            }
        }

        /// WCAG 2.x relative luminance.
        static func luminance(_ colour: Colour) -> Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(colour.rgb.r)
                + 0.7152 * linear(colour.rgb.g)
                + 0.0722 * linear(colour.rgb.b)
        }

        static func contrast(_ a: Colour, _ b: Colour) -> Double {
            let first = luminance(a)
            let second = luminance(b)
            let hi = max(first, second)
            let lo = min(first, second)
            return (hi + 0.05) / (lo + 0.05)
        }

        static func format(_ ratio: Double) -> String {
            String(format: "%.2f", ratio)
        }

        // MARK: - resolution

        /// Follow one `--token` to an opaque colour, the way the cascade does inside a
        /// scheme block: the block's own declaration first, then one alias hop
        /// (`--bg: var(--color-bg)`), then arc's bare `:root`, then the framework sheet.
        ///
        /// Returns nil when the token is undeclared or the value is not a hex colour —
        /// both are instrument failures, reported rather than skipped.
        static func colour(for token: String, in block: SheetTokenResolutionTests.ThemeBlock) -> Colour? {
            let arcRoot = SheetTokenResolutionTests.rootDeclarations(SheetTokenResolutionTests.sheet)
            let frameworkRoot = SheetTokenResolutionTests.rootDeclarations(SheetTokenResolutionTests.frameworkSheet)
            var seen: Set<String> = []
            var current = token
            for _ in 0..<4 {
                guard seen.insert(current).inserted else { return nil }
                let raw = block.declarations[current] ?? arcRoot[current] ?? frameworkRoot[current]
                guard let value = raw else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let direct = Colour(trimmed) { return direct }
                // one alias hop: `var(--other)` with no fallback
                if trimmed.hasPrefix("var(") {
                    let inner = trimmed.dropFirst(4).dropLast(trimmed.hasSuffix(")") ? 1 : 0)
                    if inner.contains(",") { return nil } // a fallback is not a value
                    current = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }
                return nil
            }
            return nil
        }

        // MARK: - the assertion

        @Test("every scheme's --link clears AA on its own --bg")
        func everyLinkClearsAAOnItsOwnBackground() {
            let blocks = SheetTokenResolutionTests.allThemeBlocks()
            var measured = 0
            var failures: [String] = []

            for block in blocks {
                guard let link = Self.colour(for: "--link", in: block) else {
                    failures.append("\(block.label): --link does not resolve to an opaque hex colour in this block")
                    continue
                }
                guard let background = Self.colour(for: "--bg", in: block) else {
                    failures.append("\(block.label): --bg does not resolve to an opaque hex colour in this block")
                    continue
                }
                let ratio = Self.contrast(link, background)
                measured += 1
                if ratio < Self.required {
                    failures.append(
                        "\(block.label): --link \(link) on --bg \(background) = \(Self.format(ratio)):1, needs \(Self.format(Self.required)):1"
                    )
                }
            }

            // the inventory, in one grep-able line per block — the failure list is the
            // authoritative reading; the suite summary is only the tally.
            for failure in failures {
                print("LINK-CONTRAST-FAIL \(failure)")
            }
            print("link contrast: \(measured) of \(blocks.count) scheme×mode blocks measured, \(failures.count) below \(Self.format(Self.required)):1")

            // the matrix itself: 27 schemes × (light, system, dark, system-in-dark-media).
            // Pinned so a provider that stops emitting blocks cannot make this test pass
            // by measuring less.
            #expect(blocks.isEmpty == false)
            #expect(blocks.count == 108, "expected 108 scheme×mode blocks (27 schemes × 4), measured \(blocks.count)")

            for failure in failures {
                Issue.record(Comment(rawValue: failure))
            }
        }
    }
}
