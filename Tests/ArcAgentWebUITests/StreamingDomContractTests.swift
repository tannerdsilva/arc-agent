import Foundation
import Testing

@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// the streaming DOM contract: the live turn and committed messages carry stable,
    /// addressable ids, so a fragment update can target one node instead of re-rendering
    /// the transcript it is streaming into (see
    /// `.hermes/plans/2026-10-01_164907-webui-streaming-dom-stability.md`).
    ///
    /// these tests scan the renderer sources, the same way `ClickIdentityContractTests`
    /// scans the click-identity contract: losing one of these strings is silent at
    /// runtime (an update lands nowhere, or everywhere), so the pin is the test.
    @Suite("Streaming DOM contract", .serialized)
    struct StreamingDomContractTests {

        private static let sourcesRoot = "Sources/ArcWebUI"

        private static func views() -> String {
            let path = "\(sourcesRoot)/Views.swift"
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return clientText(text)
        }

        private static func actions() -> String {
            let path = "\(sourcesRoot)/Actions.swift"
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return clientText(text)
        }

        /// the pure turn-event mapper: where the live turn's fields are written
        /// now that the turn runs on `ArcAgent.streamTurn` (CONVERGE A7).
        private static func turnEvents() -> String {
            let path = "\(sourcesRoot)/TurnEvents.swift"
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return clientText(text)
        }

        /// text as the client sees it: `\"` unescaped (the plain and escaped spellings of an
        /// attribute are one shape).
        static func clientText(_ text: String) -> String {
            text.replacingOccurrences(of: "\\\"", with: "\"")
        }

        @Test("the live turn and its body are addressable")
        func liveTurnIsAddressable() async {
            // the live turn is typed now: pin the RENDERED node ids, which are
            // exactly what the streaming text ops target.
            let live = await RenderedMarkup.liveTurn()
            #expect(live.contains("id=\"live-turn\""), "liveMessageHTML must carry id=\"live-turn\"")
            #expect(live.contains("id=\"live-turn-body\""), "the live body must carry id=\"live-turn-body\"")
            #expect(live.contains("id=\"live-turn-text\""), "the streaming text must sit in a stable span (id=\"live-turn-text\") for text-op writes")
            let views = Self.views()
            #expect(views.contains("innerID: \"live-turn-thinking\""),
                    "the streamed reasoning must request its stable span (id=\"live-turn-thinking\")")
            #expect(live.contains("id=\"live-turn-thinking\""),
                    "the reasoning span must be in the render, not materialize later")
        }

        @Test("token pushes are text ops into the stable spans")
        func tokenPushesAreTextOps() {
            let actions = Self.actions()
            #expect(actions.contains("FragmentUpdate.text(id: \"live-turn-text\""),
                    "the streaming loop must write tokens with the text op, not by re-rendering the node")
            #expect(actions.contains("FragmentUpdate.text(id: \"live-turn-thinking\""),
                    "streamed reasoning must be a text op too")
        }

        @Test("tool progress is a name plus a client-ticked clock")
        func toolProgressIsNamedAndTimed() async {
            let actions = Self.actions()
            #expect(actions.contains("TurnLiveState.apply(event, to: live)"),
                    "the turn loop must drive the live turn from the agent's event stream")
            let mapper = Self.turnEvents()
            #expect(mapper.contains("next.toolName = name"),
                    "the mapper must stamp the running tool's name for the status line")
            #expect(mapper.contains("next.toolStartedAt = now"),
                    "the mapper must stamp when the tool started, for the client-ticked clock")
            let live = await RenderedMarkup.liveTurn()
            #expect(live.contains("read_file"), "the tool status line must render the tool name")
            #expect(live.contains("data-elapsed") && live.contains("data-started="),
                    "the tool clock must reuse the client-ticked elapsed span")
        }

        @Test("committed turns and messages are addressable")
        func committedUnitsAreAddressable() async {
            let block = await RenderedMarkup.turnBlock()
            #expect(block.contains("id=\"turn-1\""), "turnBlockHTML must carry id=\"turn-<turnIndex>\"")
            // the messages are typed now: prove the addresses on RENDERED rows.
            // the streaming push targets these ids, so a missing one is a
            // silently dropped update, not a cosmetic difference.
            let rendered = await RenderedMarkup.addressedMessages()
            #expect(rendered.contains("id=\"msg-user-0\""),
                    "user messages must be addressable as id=\"msg-user-<rawIdx>\"")
            #expect(rendered.contains("id=\"msg-1\""),
                    "assistant and tool messages must carry id=\"msg-<rawIdx>\"")
            #expect(!rendered.contains("id=\"\""), "an address attribute must never render empty")
        }

        @Test("the streaming push targets the live node, not the transcript")
        func streamingPushTargetsLiveNode() {
            let actions = Self.actions()
            guard let start = actions.range(of: "func liveFragments()"),
                  let end = actions.range(of: "func ", range: start.upperBound..<actions.endIndex) else {
                Issue.record("liveFragments() not found in Actions.swift")
                return
            }
            let body = String(actions[start.lowerBound..<end.lowerBound])
            #expect(body.contains("id: \"live-turn\""), "liveFragments() must push the live-turn fragment")
            #expect(!body.contains("id: \"chat-inner\""),
                    "liveFragments() must not push chat-inner — a streaming turn must never re-render the transcript")
        }

        @Test("the streaming fragment refuses view transitions")
        func streamingFragmentRefusesTransitions() {
            let actions = Self.actions()
            guard let start = actions.range(of: "func liveFragments()"),
                  let end = actions.range(of: "func ", range: start.upperBound..<actions.endIndex) else {
                Issue.record("liveFragments() not found in Actions.swift")
                return
            }
            let body = String(actions[start.lowerBound..<end.lowerBound])
            #expect(body.contains("transition: false"),
                    "the hot streaming fragment must opt out of the client's view-transition animation")
        }
    }
}