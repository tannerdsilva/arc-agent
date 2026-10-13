import Foundation
import Testing
import WebUICore

@testable import ArcWebUI

/// Push hygiene: streaming paths re-emit identical chrome between token pushes
/// (the composer flyout, the TPS chip's neighbours), and the client would tear
/// down and rebuild identical nodes for nothing. `PushDeduper` drops a repeat
/// push for the same id; empty html (the remove-the-node signal) always passes —
/// a skipped removal could strand a node an intervening parent push re-created.
@Suite("Streaming push hygiene")
struct StreamingPushHygieneTests {

    @Test("an identical repeat push is dropped")
    func dedupesIdentical() async {
        let deduper = PushDeduper()
        let batch = [FragmentUpdate(id: "live-turn", html: "<div class=\"msg\">a</div>")]
        #expect(await deduper.filter(batch).count == 1)
        #expect(await deduper.filter(batch).isEmpty)
    }

    @Test("changed html passes; empty html always passes")
    func changedAndEmptyPass() async {
        let deduper = PushDeduper()
        _ = await deduper.filter([FragmentUpdate(id: "x", html: "<p>1</p>")])
        #expect(await deduper.filter([FragmentUpdate(id: "x", html: "<p>2</p>")]).count == 1)
        _ = await deduper.filter([FragmentUpdate(id: "y", html: "")])
        #expect(await deduper.filter([FragmentUpdate(id: "y", html: "")]).count == 1)
    }

    @Test("ids are deduped independently")
    func independentIDs() async {
        let deduper = PushDeduper()
        _ = await deduper.filter([
            FragmentUpdate(id: "a", html: "1"),
            FragmentUpdate(id: "b", html: "1"),
        ])
        let out = await deduper.filter([
            FragmentUpdate(id: "a", html: "1"),
            FragmentUpdate(id: "b", html: "2"),
        ])
        #expect(out.count == 1)
        #expect(out.first?.id == "b")
    }
}