import Foundation
import Testing

import ArcTheme
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The sidebar row's geometry contract: a running turn must not move the
    /// conversation list.
    ///
    /// Measured in Chrome against the served sheet (2026-10-14, panel 280px,
    /// row content 211px): the live-status pill's label — `Running
    /// pkg_overview…`, 162px — does not fit the meta line beside the count and
    /// the time, and the item that absorbed the shortfall was the **anonymous
    /// count text**: it wrapped into three lines (3 × 18px = 54px), so the row
    /// grew 56 -> 92px while `align-items: stretch` pulled the pill to 54px,
    /// painted on top of the count. Measured before/after on the live page:
    /// row 92 -> 56, meta 54 -> 18, pill 54x162 -> 17x124 with the label
    /// ellipsised, pill right edge 20px past the row's ⋮ actions -> 0.
    ///
    /// The panel re-render that a session delete triggers is what puts the pill
    /// into the DOM (a streaming turn only pushes `#live-turn`), which is why the
    /// owner met it as "delete a chat below the active one and the geometry goes
    /// weird" — the fix is in the row, not in the delete.
    ///
    /// The pins pair the emitted class with the sheet selector it keys on (a
    /// rename on either side fails here instead of re-breaking the row) and pin
    /// the declarations the geometry depends on. CSS pins read the source, the
    /// way `UXHardeningContractTests` reads it; the built product is pinned too,
    /// because the sheet the client gets is the minified one.
    @Suite("Sidebar row geometry contract", .serialized)
    struct SidebarRowGeometryContractTests {

        private static func source(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }

        /// text as the client sees it: `\"` unescaped, so the plain and the
        /// escaped spelling of an attribute are one shape.
        private static func clientText(_ text: String) -> String {
            text.replacingOccurrences(of: "\\\"", with: "\"")
        }

        private static var sheet: String { source("Sources/ArcTheme/ChromeSheet.swift") }
        private static var views: String { clientText(source("Sources/ArcWebUI/Views.swift")) }

        @Test("the meta line cannot wrap, so a tight row does not fold the count")
        func metaLineCannotWrap() {
            #expect(
                Self.sheet.contains(
                    ".sess-meta { font-size: 12px; color: var(--muted); display: flex; gap: 6px; align-items: center; min-width: 0; white-space: nowrap; }"
                ),
                "the count text is an anonymous flex item: without nowrap it wraps to three lines (54px) when the pill cannot fit, growing the row 56 -> 92px"
            )
        }

        @Test("the status pill fits inside the meta line's height")
        func pillFitsTheMetaLine() {
            // 11.5px x 1.35 = 15.5px + 2px of border = 17.5px, inside the meta
            // line's 18px — so the row's height is the same with and without a
            // running turn.
            #expect(
                Self.sheet.contains("line-height: 1.35; white-space: nowrap;"),
                "at line-height 1.7 the pill measured 21.5px and every row it appeared on grew"
            )
            #expect(
                !Self.sheet.contains("line-height: 1.7; white-space: nowrap;"),
                "the 1.7 pill is the height that made a running turn resize the list"
            )
        }

        @Test("the pill takes the shortfall; the count and the time stay whole")
        func pillTakesTheShortfall() {
            let css = Self.sheet
            #expect(
                css.contains("min-width: 0; max-width: 100%; overflow: hidden;"),
                "a rigid pill painted 20px over the row's ⋮ actions instead of shrinking"
            )
            #expect(
                css.contains(".sess-status-label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }"),
                "the ellipsis needs its own box: a flex container cannot ellipsise an anonymous text node"
            )
            #expect(
                css.contains("flex: 0 0 auto;\n      width: 5px; height: 5px;"),
                "the status dot must keep its 5px while the label takes the whole shortfall"
            )
        }

        @Test("`liveStatusPill` emits the node the sheet keys on")
        func pillEmitsItsLabelNode() {
            #expect(
                Self.views.contains(
                    "<span class=\"sess-status\"><span class=\"sess-status-dot\"></span><span class=\"sess-status-label\">\\(esc(label))</span></span>"
                ),
                "the pill's label must be a real node for `.sess-status-label` to constrain"
            )
        }

        @Test("the fix survives the minifier")
        func minifiedSheetKeepsTheFix() {
            let built = ThemeSheetAssets.text.filter { !$0.isWhitespace }
            #expect(
                built.contains(
                    ".sess-meta{font-size:12px;color:var(--muted);display:flex;gap:6px;align-items:center;min-width:0;white-space:nowrap;"
                ),
                "the client gets the minified sheet — a nowrap eaten there is the bug back"
            )
            #expect(
                built.contains(".sess-status-label{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"),
                "the label's ellipsis box must reach the client"
            )
        }
    }
}