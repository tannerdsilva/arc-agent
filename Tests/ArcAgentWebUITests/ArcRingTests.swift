@testable import ArcWebUI
import ArcAgentCore
import Foundation
import Testing
import WebUI

extension ArcWebUITestRoot {

    @Suite("Arc ring", .serialized)
    struct ArcRingTests {

        /// extract the `<svg>...</svg>` substring from legacy markup, or nil.
        private static func svg(_ html: String) -> String? {
            guard let start = html.range(of: "<svg") else { return nil }
            let from = start.upperBound
            guard let endRange = html.range(of: "</svg>", range: from..<html.endIndex) else { return nil }
            return String(html[start.lowerBound..<endRange.upperBound])
        }

        @Test("arc ring matches legacy at 0 percent")
        func arcRingMatchesLegacyAtZeroPercent() async {
            let app = AppState(renderFixture: .init())
            let session = Session(
                id: "sess-ring-0",
                messages: [
                    Message(
                        role: .assistant, content: "x",
                        usage: Usage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
                    ),
                ]
            )
            let legacy = await app.ctxIndicatorHTML(session)
            #expect(!legacy.isEmpty, "legacy produced empty markup")
            let legacySVG = Self.svg(legacy)!
            let ring = ArcRing(percentage: 0).markup.html
            #expect(
                ParityNormalize.normalize(ring) == ParityNormalize.normalize(legacySVG),
                "legacy: \(legacySVG)\nring: \(ring)"
            )
        }

        @Test("arc ring matches legacy at 37 percent")
        func arcRingMatchesLegacyAt37Percent() async {
            let app = AppState(renderFixture: .init())
            // contextLength defaults to 1_048_576; usedTokens = 387_973 → 37%
            let used = Int((Double(1_048_576) * 0.37).rounded()) // 387973
            let session = Session(
                id: "sess-ring-37",
                messages: [
                    Message(
                        role: .assistant, content: "x",
                        usage: Usage(promptTokens: used, completionTokens: 0, totalTokens: used)
                    ),
                ]
            )
            let legacy = await app.ctxIndicatorHTML(session)
            #expect(!legacy.isEmpty, "legacy produced empty markup")
            let legacySVG = Self.svg(legacy)!
            let ring = ArcRing(percentage: 37).markup.html
            #expect(
                ParityNormalize.normalize(ring) == ParityNormalize.normalize(legacySVG),
                "legacy: \(legacySVG)\nring: \(ring)"
            )
        }

        @Test("arc ring matches legacy at 100 percent")
        func arcRingMatchesLegacyAt100Percent() async {
            let app = AppState(renderFixture: .init())
            let session = Session(
                id: "sess-ring-100",
                messages: [
                    Message(
                        role: .assistant, content: "x",
                        usage: Usage(promptTokens: 1_048_576, completionTokens: 0, totalTokens: 1_048_576)
                    ),
                ]
            )
            let legacy = await app.ctxIndicatorHTML(session)
            #expect(!legacy.isEmpty, "legacy produced empty markup")
            let legacySVG = Self.svg(legacy)!
            let ring = ArcRing(percentage: 100).markup.html
            #expect(
                ParityNormalize.normalize(ring) == ParityNormalize.normalize(legacySVG),
                "legacy: \(legacySVG)\nring: \(ring)"
            )
        }

        @Test("dash values are pinned for known percentage")
        func dashValuesArePinned() {
            let ring = ArcRing(percentage: 50).markup.html
            // circumference 61.261056745, half → offset = 30.6305283725
            #expect(ring.contains("style=\"stroke-dasharray:61.261056745;stroke-dashoffset:30.6305283725\""))
            #expect(ring.contains("class=\"ctx-ring-track\""))
            #expect(ring.contains("class=\"ctx-ring-value\""))
            #expect(ring.contains("viewBox=\"0 0 24 24\""))
            #expect(ring.contains("r=\"9.75\""))
            #expect(ring.hasPrefix("<svg class=\"ctx-ring-svg\""))
            #expect(ring.hasSuffix("</svg>"))
            // exactly two circles, no wrapper element, no Raw
            let openCount = ring.split(separator: "<", omittingEmptySubsequences: true)
                .filter { $0.hasPrefix("circle") || $0.hasPrefix("/circle") }.count
            #expect(openCount == 4, "expected exactly two <circle> and two </circle>, got \(ring)")
            #expect(!ring.contains("Raw"))
        }
    }
}
