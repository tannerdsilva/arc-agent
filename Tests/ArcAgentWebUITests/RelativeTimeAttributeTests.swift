import Foundation
import Testing

@testable import ArcWebUI

// the relative-time ladder used to be written twice: `AppState.relTimeLabel`
// painted the first frame server-side, and `overlay.js`'s `relLabel` repainted
// the `<span data-reltime>` labels in place every 60 s. `Scripts/relative-time-parity.mjs`
// pinned the two together by extracting `relLabel` from the overlay.
//
// no-webui 2.6.0 dispatches `data-reltime` itself (the engine's `relText` is the
// same ladder, one asset over), so `relLabel` and the node harness are gone. what
// remains arc-side is the CONTRACT the engine reads: a rendered timestamp must
// carry `data-reltime` as epoch milliseconds and must already show the ladder's
// label before any script runs. a timestamp that lost the attribute would stop
// ticking and nothing else in this tree would notice.
extension ArcWebUITestRoot {

    @Suite("Relative time attribute", .serialized)
    struct RelativeTimeAttributeTests {

        @Test("a rendered timestamp carries the ticking attribute and its first paint")
        func timestampsCarryDataReltime() async {
            let panel = await RenderedMarkup.panelWithRows()
            // 1_700_000_000s is the fixture's `updatedAt` for both rows.
            let epochMs = 1_700_000_000_000
            #expect(panel.contains("data-reltime=\"\(epochMs)\""),
                    "the session meta must carry epoch milliseconds in data-reltime, or the engine never repaints it")
            let tag = panel.range(of: #"<span [^>]*data-reltime="\#(epochMs)"[^>]*>[^<]*</span>"#,
                                  options: .regularExpression).map { String(panel[$0]) }
            #expect(tag != nil, "the timestamp must render as a text-bearing span")
            // the server paints the ladder's label for the first frame; the
            // engine only re-paints it on its 60 s interval. A blank label means
            // the page shows an empty meta until the timer fires.
            let label = tag.flatMap { value -> String? in
                guard let open = value.firstIndex(of: ">"),
                      let close = value.lastIndex(of: "<") else { return nil }
                return String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            }
            #expect(label?.isEmpty == false,
                    "the first paint must not be blank: \(tag ?? "no tag")")
        }
    }
}
