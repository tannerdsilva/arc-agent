import Foundation
import Testing

@testable import ArcWebUI

/// the streaming DOM contract: the live turn and committed messages carry stable,
/// addressable ids, so a fragment update can target one node instead of re-rendering
/// the transcript it is streaming into (see
/// `.hermes/plans/2026-10-01_164907-webui-streaming-dom-stability.md`).
///
/// these tests scan the renderer sources, the same way `ClickIdentityContractTests`
/// scans the click-identity contract: losing one of these strings is silent at
/// runtime (an update lands nowhere, or everywhere), so the pin is the test.
@Suite("Streaming DOM contract")
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

    /// text as the client sees it: `\"` unescaped (the plain and escaped spellings of an
    /// attribute are one shape).
    static func clientText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"")
    }

    @Test("the live turn and its body are addressable")
    func liveTurnIsAddressable() {
        let views = Self.views()
        #expect(views.contains("id=\"live-turn\""), "liveMessageHTML must carry id=\"live-turn\"")
        #expect(views.contains("id=\"live-turn-body\""), "the live body must carry id=\"live-turn-body\"")
        #expect(views.contains("id=\"live-turn-text\""), "the streaming text must sit in a stable span (id=\"live-turn-text\") for text-op writes")
        #expect(views.contains("innerID: \"live-turn-thinking\""),
                "the streamed reasoning must request its stable span (id=\"live-turn-thinking\")")
        #expect(views.contains("\"<span id=\"\\($0)\">\""),
                "the reasoning-row builder must emit the span with the interpolated id")
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
    func toolProgressIsNamedAndTimed() {
        let actions = Self.actions()
        #expect(actions.contains("toolName = call.function.name"),
                "the tool loop must stamp the running tool's name for the status line")
        let views = Self.views()
        #expect(views.contains("live.toolName"), "the tool status line must render the tool name")
        #expect(views.contains("data-elapsed data-started="),
                "the tool clock must reuse the client-ticked elapsed span")
    }

    @Test("committed turns and messages are addressable")
    func committedUnitsAreAddressable() {
        let views = Self.views()
        #expect(views.contains("id=\"turn-\\(turnIndex)\""), "turnBlockHTML must carry id=\"turn-<turnIndex>\"")
        #expect(views.components(separatedBy: "id=\"msg-\\(rawIdx)\"").count == 3,
                "assistant and tool messageHTML variants must carry id=\"msg-<rawIdx>\"")
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