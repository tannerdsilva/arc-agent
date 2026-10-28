import Foundation
import Testing
import WebUICore
import WebUIState

@testable import ArcWebUI

// The push door, tested at its own boundary.
//
// `PushEdge` is the single seam between every producer in arc (an action
// handler, the turn presenter, a streamer) and the wire. Two kinds of batch
// cross it and they must be treated differently:
//
//   - structural (`nil` / `.replace`): the producer's html is an opinion. What
//     the client needs is the difference between what it holds and a fresh
//     render, so the edge renders and ships the differ's frames.
//   - delta (`.text` / `.append`): a write against a node another producer owns.
//     It crosses verbatim, and it must not cost a render.
//
// The fixtures are arc's own shape: `#app` is the root the client patches by,
// `#panel` is a chrome region, and `#live-turn` carries the two spans the token
// writer owns — the spans the policy excludes from every diff.

/// a page in arc's shape, one line so a region's bytes are exactly the string a
/// frame has to carry.
private func page(
    panel: String = "p",
    text: String = "",
    thinking: String = "",
    busy: String = "0"
) -> String {
    #"<div id="app" class="app" data-size="m"><div id="live-turn" class="live-turn" data-busy="\#(busy)"><span id="live-turn-text">\#(text)</span><b id="live-turn-thinking">\#(thinking)</b></div><div id="panel" class="panel">\#(panel)</div></div>"#
}

/// `#panel`'s element bytes — what a derived frame for that region must carry.
private func panelElement(_ body: String) -> String {
    #"<div id="panel" class="panel">\#(body)</div>"#
}

/// one derived-frame case: the render the edge is asked to describe, and the
/// frames it must answer.
/// internal, not private: a `@Test` parameter may not use a fileprivate type.
struct FrameCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// the render after the change.
    let after: String
    /// the frame ids, in wire order. empty means nothing may cross.
    let expected: [String]
    /// true when the answer must be the whole root: bytes no region covers have
    /// no patch shape, so a partial patch would leave the client stale.
    let fullPage: Bool
    var testDescription: String { name }
}

private let frameCases: [FrameCase] = [
    // the token writer owns this span; a structural render that carries the
    // token's bytes must send nothing at all.
    FrameCase(
        name: "text-only change in a token-owned span",
        after: page(text: "abc"),
        expected: [],
        fullPage: false
    ),
    // the changed bytes are the live node's own (its busy attribute), so the
    // node ships and the excluded children never appear on the wire.
    FrameCase(
        name: "structural change inside #live-turn",
        after: page(busy: "1"),
        expected: ["live-turn"],
        fullPage: false
    ),
    // bytes outside every region: nothing can carry them but the root.
    FrameCase(
        name: "change outside every region",
        after: page() + #"<p>tail</p>"#,
        expected: ["app"],
        fullPage: true
    ),
]

extension ArcWebUITestRoot {
    /// The push door: what crosses the wire, and what the producer's html is
    /// worth.
    @Suite("Push diff", .serialized)
    struct PushDiffTests {

        /// The render side: the markup a fresh `app.appShell()` would answer, and
        /// a count, so a delta batch can prove it never rendered at all.
        private actor RenderBox {
            private(set) var renders = 0
            private var markup: String

            init(_ markup: String) { self.markup = markup }

            func set(_ next: String) { markup = next }

            func render() -> String {
                renders += 1
                return markup
            }
        }

        /// The wire: every batch, in order.
        private actor Wire {
            private(set) var batches: [[FragmentUpdate]] = []

            var flat: [FragmentUpdate] { batches.flatMap { $0 } }

            func record(_ batch: [FragmentUpdate]) { batches.append(batch) }
        }

        private struct Rig {
            let edge: PushEdge
            let wire: Wire
            let box: RenderBox
        }

        /// a door seeded with `seed`, whose next render answers `render`.
        private func makeRig(seed: String, render: String) -> Rig {
            let box = RenderBox(render)
            let wire = Wire()
            let edge = PushEdge(
                differ: PageDiffer(policy: PushEdge.livePolicy),
                render: { await box.render() },
                broadcast: { await wire.record($0) }
            )
            edge.seed(seed)
            return Rig(edge: edge, wire: wire, box: box)
        }

        @Test("a replace-html batch is derived, not forwarded")
        func replaceBatchIsDerived() async {
            let rig = makeRig(seed: page(panel: "old"), render: page(panel: "fresh"))
            // a producer's html is stale by construction: it was assembled before
            // the render that describes the same change.
            await rig.edge.push([FragmentUpdate(id: "panel", html: panelElement("STALE INPUT"))])

            let batches = await rig.wire.batches
            #expect(batches.count == 1)
            #expect(batches.first?.map(\.id) == ["panel"])
            #expect(
                batches.first?.first?.html == panelElement("fresh"),
                "the frame must carry the render's bytes, not the producer's")
            let wireHTML = await rig.wire.flat.map(\.html).joined()
            #expect(!wireHTML.contains("STALE INPUT"), "the producer's html never reaches the wire")
            #expect(await rig.box.renders == 1, "one structural batch is one render")
        }

        @Test("a text batch passes through untouched")
        func textBatchPassesThrough() async {
            let update = FragmentUpdate.text(id: "live-turn-text", value: "abc", transition: false)
            // the render disagrees on purpose: a delta is not re-derived, so the
            // edge must never look at it.
            let rig = makeRig(seed: page(), render: page(text: "zzz"))
            await rig.edge.push([update])

            let batches = await rig.wire.batches
            #expect(batches == [[update]], "a delta is written verbatim, transition flag included")
            #expect(batches.first?.first?.op == .text)
            #expect(batches.first?.first?.text == "abc")
            #expect(
                await rig.box.renders == 0,
                "a delta must never cost a render: the token path is the hot one")
        }

        @Test("a mixed batch ships the structure, then the deltas")
        func mixedBatchPartitions() async {
            let rig = makeRig(seed: page(panel: "old"), render: page(panel: "fresh"))
            let delta = FragmentUpdate.text(id: "live-turn-text", value: "abc", transition: false)
            // the producer names #main — a region the render did not change. The
            // derived batch must describe what actually moved.
            await rig.edge.push([FragmentUpdate(id: "main", html: #"<div id="main">STALE</div>"#), delta])

            let batches = await rig.wire.batches
            #expect(batches.count == 2, "a mixed batch is two broadcasts, not one")
            #expect(batches.first?.map(\.id) == ["panel"], "structure first, and derived")
            #expect(
                batches.first?.allSatisfy { $0.op == nil || $0.op == .replace } == true,
                "the structural broadcast carries structure only")
            #expect(batches.last == [delta], "the delta follows verbatim")
        }

        @Test("a seeded first push stays minimal")
        func seededFirstPushStaysMinimal() async {
            let rig = makeRig(seed: page(panel: "old"), render: page(panel: "fresh"))
            // the pre-slice shape of a chrome refresh: the producer names the whole
            // root. The seed is what turns that into a region.
            await rig.edge.push([FragmentUpdate(id: "app", html: page(panel: "STALE"))])

            let batches = await rig.wire.batches
            #expect(batches.count == 1)
            #expect(
                batches.first?.map(\.id) == ["panel"],
                "a seeded differ patches the region that moved, not the root")
            #expect(batches.first?.first?.html == panelElement("fresh"))
        }

        @Test("derived frames never target an excluded region", arguments: frameCases)
        func derivedFramesRespectExclusions(_ state: FrameCase) async {
            let before = page()
            let rig = makeRig(seed: before, render: state.after)
            await rig.edge.push([FragmentUpdate(id: "app", html: before)])

            let frames = await rig.wire.flat
            #expect(frames.map(\.id) == state.expected)
            #expect(
                frames.allSatisfy { $0.id != "live-turn-text" && $0.id != "live-turn-thinking" },
                "the token-owned spans are written by op:text; a replace would fight that writer")
            for frame in frames {
                #expect(
                    state.after.contains(frame.html),
                    "every frame must carry bytes the render actually produced")
                #expect(
                    !before.contains(frame.html),
                    "a frame for a changed region must not repeat what the client already holds")
            }
            if state.fullPage {
                #expect(frames.count == 1, "bytes no region covers escalate to one root frame")
                #expect(frames.first?.html == state.after)
            }
        }
    }
}

/// the seeding contract, proved on the REAL page rather than a synthetic one.
///
/// `PushEdge` seeds from one render and diffs the next, so two renders of the
/// same state have to be byte-identical. if they are not, every structural push
/// is answered with a whole-root replace: correct, and useless — the client
/// re-mounts its entire page on each interaction.
@Suite("push seeding on the real page")
struct PushSeedingTests {
	@Test("two renders of the same state are byte-identical")
	func shellRenderIsStable() async {
		let first = await RenderedMarkup.page()
		let second = await RenderedMarkup.page()
		#expect(first == second, "a non-deterministic render invalidates seeding")
	}

	@Test("a seeded differ answers an unchanged render with nothing")
	func seededDiffOfTheRealPageIsEmpty() async {
		let page = await RenderedMarkup.page()
		let differ = PageDiffer(policy: PushEdge.livePolicy)
		differ.seed(withMarkup: page)
		#expect(
			differ.messages(forMarkup: page, root: "app").isEmpty,
			"the boot page is what the client already holds; nothing may be pushed for it")
	}
}
