import Foundation
import Testing
import WebUICore
import WebUIState

@testable import ArcWebUI

// The producer door, tested at its own boundary.
//
// `PushEdge` is the single seam between the producers that have no dispatch
// session to borrow — the turn loop's structural boundaries, a background task —
// and the wire. Two kinds of batch cross it and they must be treated
// differently:
//
//   - structural (`nil` / `.replace`, or an empty batch): the producer's html is
//     an opinion. The client needs the difference between what it holds and a
//     fresh render, and only the server can derive that — it served the page, so
//     it owns the baseline. The door asks the server to refresh the pages it
//     served and forwards nothing at all.
//   - delta (`.text` / `.append`): a write against a node another producer owns.
//     It crosses verbatim, and it must not cost a refresh.
//
// ## What was retired here, and why (A10b)
//
// - **`edge.seed` and the `PageDiffer` construction.** A host-side differ meant
//   two owners of one page's baseline. The server has owned the baseline the
//   client actually holds since 2.9.0 (`WebUIServerConfig.refreshPolicy` +
//   `lastRender`), so a seed was a second, unprovable copy — and every assertion
//   built on it pinned the differ's internals rather than the page.
// - **`seededFirstPushStaysMinimal`** — it proved that a seeded differ patches a
//   region instead of the root. Minimality is the server's now, and
//   `TwoPopulationDispatchTests.refreshShipsTheChangedRegion` proves a refresh
//   ships exactly the region whose bytes moved.
// - **`removalEscalatesToTheRoot`, `toastsChangeCarriesTheContainer`,
//   `derivedFramesRespectExclusions`** — they asked the door what a render
//   *would* ship. They moved to `ProducerRefreshWireTests`, which asks a real
//   `WebUIServer` over a real socket: same questions, answered by the component
//   that answers them in production.
//
// The policy itself did not move out of reach: `AppShell.refreshPolicy` carries
// the exact value the retired door policy did, and one test below pins it field
// by field.

extension ArcWebUITestRoot {
    /// The producer door: what crosses the wire, and what the producer's html is
    /// worth.
    @Suite("Push diff", .serialized)
    struct PushDiffTests {

        /// The door's two sinks as one journal, so "structure before deltas" is
        /// an ordered fact rather than two totals that cannot be compared.
        private actor Door {
            private(set) var events: [String] = []
            private(set) var batches: [[FragmentUpdate]] = []

            var flat: [FragmentUpdate] { batches.flatMap { $0 } }
            var refreshes: Int { events.filter { $0 == "refresh" }.count }

            func refresh() { events.append("refresh") }

            func record(_ updates: [FragmentUpdate]) {
                events.append("delta:" + updates.map(\.id).joined(separator: ","))
                batches.append(updates)
            }
        }

        private struct Rig {
            let edge: PushEdge
            let door: Door
        }

        private func makeRig() -> Rig {
            let door = Door()
            let edge = PushEdge(
                refresh: { await door.refresh() },
                broadcast: { await door.record($0) }
            )
            return Rig(edge: edge, door: door)
        }

        @Test("a structural batch asks the server to refresh, and forwards no html")
        func structuralBatchRefreshesAndForwardsNothing() async {
            let rig = makeRig()
            // a producer's html is stale by construction: it was assembled before
            // the render that describes the same change.
            await rig.edge.push([FragmentUpdate(id: "panel", html: "<div id=\"panel\">STALE INPUT</div>")])

            let events = await rig.door.events
            #expect(events == ["refresh"], "a structural batch is one refresh and nothing else, got \(events)")
            let wireHTML = await rig.door.flat.map(\.html).joined()
            #expect(!wireHTML.contains("STALE INPUT"), "the producer's html reached the wire")
            #expect(
                await rig.door.batches.isEmpty,
                "the door broadcast a structural frame: the refresh's diff decides what ships, never the producer")
        }

        @Test("a text batch passes through untouched")
        func textBatchPassesThrough() async {
            let update = FragmentUpdate.text(id: "live-turn-text", value: "abc", transition: false)
            let rig = makeRig()
            await rig.edge.push([update])

            let batches = await rig.door.batches
            #expect(batches == [[update]], "a delta is written verbatim, transition flag included")
            #expect(batches.first?.first?.op == .text)
            #expect(batches.first?.first?.text == "abc")
            #expect(
                await rig.door.refreshes == 0,
                "a delta must never cost a refresh: the token path is the hot one")
        }

        @Test("an empty batch still asks the door to look at the page")
        func emptyBatchAsksTheEdgeToLook() async {
            // the nudge: a producer that changed structure says nothing else. an
            // empty batch the door ignored would leave the page stale, which is
            // the one failure mode this slice must not introduce. Whether bytes
            // moved is the server's answer, and a refresh that reproduces the
            // page sends nothing — `ProducerRefreshWireTests` proves that half.
            let rig = makeRig()
            await rig.edge.push([])

            #expect(await rig.door.refreshes == 1, "the nudge costs exactly one refresh")
            #expect(await rig.door.batches.isEmpty, "an empty batch ships nothing at all — not even an empty batch")

            // and the look is never skipped, however quiet the page is.
            await rig.edge.push([])
            #expect(await rig.door.refreshes == 2, "a second nudge must ask again: the door does not debounce the server")
        }

        @Test("a handler's .refresh never crosses the producer door")
        func handlerClickAnswersRefresh() async {
            // 2.9.0/2.12.0: a render-time or `@Wired` handler answers
            // `HandlerOutcome.refresh`, and the SERVER re-renders the dispatch
            // session's page against the baseline it owns. The interaction
            // therefore never crosses `PushEdge` — a second diff regime over one
            // page is exactly what D2 rejects. The end-to-end frame proof is
            // `TwoPopulationDispatchTests.refreshShipsTheChangedRegion()`.
            let app = AppState(renderFixture: .init())
            let rig = makeRig()
            let router = EventRouter()
            _ = await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await app.settingsMain().markup.html
            }

            let before = await app.settings.textSize
            let outcome = await router.dispatch(EventData(
                component: ComponentID("font-size-pick"),
                event: "click",
                data: ["targetId": .string("fsz-lg")]))

            #expect(outcome.isRefresh,
                    "a render-time handler's structural signal is the framework outcome now")
            #expect(outcome.fragments.isEmpty,
                    "the originating socket has nothing to write: the server owns the re-render")
            #expect(await app.settings.textSize != before,
                    "the click must move the setting the server's re-render reads")
            #expect(await rig.door.events.isEmpty,
                    "a handler's refresh crossed the producer door: two diff regimes over one page drift two baselines")
        }

        @Test("a mixed batch refreshes first, then ships the deltas")
        func mixedBatchPartitions() async {
            let rig = makeRig()
            let delta = FragmentUpdate.text(id: "live-turn-text", value: "abc", transition: false)
            // the producer names #main — a region the render did not change. Its
            // html must not appear either side of the door.
            await rig.edge.push([FragmentUpdate(id: "main", html: "<div id=\"main\">STALE</div>"), delta])

            let events = await rig.door.events
            #expect(events == ["refresh", "delta:live-turn-text"],
                    "structure must reach the page before the delta that may target a node it re-mounted, got \(events)")
            let batches = await rig.door.batches
            #expect(batches.count == 1, "the deltas are one broadcast")
            #expect(batches.first == [delta], "the delta follows verbatim")
            let wireHTML = await rig.door.flat.map(\.html).joined()
            #expect(!wireHTML.contains("STALE"), "a structural producer's html crossed the wire in a mixed batch")
        }

        @Test("the server re-renders this page under one policy, and the shell owns it")
        func refreshPolicyIsTheShells() {
            // the value the edge's `livePolicy` carried, moved to a neutral home
            // when the door stopped diffing. It is the ONLY dial on which regions
            // a re-render may ship, and both refresh doors (an outcome and a
            // producer push) read it here — so a restated literal, or a drift
            // between the shell and the config, is red.
            let policy = WebUIHost.serverConfig(host: "127.0.0.1", port: 8890).refreshPolicy
            #expect(policy == AppShell.refreshPolicy,
                    "the server config restates a policy instead of carrying the shell's")
            #expect(policy.identity == .elementID, "a frame must address a DOM id: the engine resolves with getElementById")
            #expect(policy.coverage == .finest, "coarse coverage drags #app onto the wire for one chrome change")
            #expect(policy.escalation == .nearestTrackedAncestor, "an appeared node must be a parent replace, not a whole page")
            #expect(policy.excluded == ["live-turn-text", "live-turn-thinking"],
                    "the token-owned spans must stay excluded: their bytes must not escalate an ancestor to a page patch")
            #expect(policy.transition == false, "a diff is not a navigation and must not animate")
        }
    }
}

/// the shell's render is the input to every refresh diff, so it has to be
/// deterministic: two renders of the same state must be byte-identical.
///
/// this used to justify `PushEdge`'s seed. It survives the seed because the
/// server's baseline is a snapshot of exactly this render — a render that varies
/// on its own makes every refresh escalate to a page patch, which is correct and
/// useless (the client re-mounts its page on each interaction).

extension ArcWebUITestRoot {
	@Suite("push seeding on the real page", .serialized)
	struct PushSeedingTests {
		@Test("two renders of the same state are byte-identical")
		func shellRenderIsStable() async {
			let first = await RenderedMarkup.page()
			let second = await RenderedMarkup.page()
			#expect(first == second, "a non-deterministic render makes every refresh a whole-page patch")
		}
	}
}
