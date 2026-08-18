import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - WebSocket Handler + Settings Panel Tests
//
// Regression: the web UI (WebSocket chat) was stuck "streaming" forever
// after every message. `WebSocketHandler.handleInbound` drained the
// session's `responses` stream with a bare `for await` and sent the
// `done` frame only when that stream ended — but `SessionHandle.responses`
// only terminates when the *whole* agent ends (input stream closed /
// error), never after a single response. So `done` was never emitted,
// the UI's `finalizeStreaming()` never ran, and the input stayed
// disabled.
//
// The fix: consume exactly ONE response per message (the same
// take-first-and-break semantics the HTTP path uses) and always emit
// `done`. The take-one logic lives in `WebSocketHandler.nextResponse`,
// which is the seam tested here.
// =========================================================================

// MARK: - nextResponse: one-response-per-message contract

@Test("nextResponse takes exactly one value and leaves the rest in the stream")
func nextResponseTakesOneLeavesRest() async {
    var stream: AsyncStream<String>!
    stream = AsyncStream { c in
        c.yield("first")
        c.yield("second")
    }
    let first = await WebSocketHandler.nextResponse(stream)
    #expect(first == "first")
    // The second value must still be available — the stream was NOT drained.
    var it = stream.makeAsyncIterator()
    let second = await it.next()
    #expect(second == "second")
}

@Test("nextResponse returns nil for an immediately-finished stream")
func nextResponseEmptyStreamIsNil() async {
    let stream = AsyncStream<String> { c in c.finish() }
    #expect(await WebSocketHandler.nextResponse(stream) == nil)
}

@Test("nextResponse terminates even when the stream never finishes (the WS chat hang)")
func nextResponseTerminatesOnNeverFinishingStream() async {
    // Models a real session's `responses` stream: the agent yields one
    // response per message, and the stream only terminates when the whole
    // agent ends. Before the fix, a drain-style consumer (`for await` with
    // no `break`) would block at this point forever, so the `done` frame
    // was never sent and the web UI hung with the input disabled.
    var stream: AsyncStream<String>!
    stream = AsyncStream { c in
        c.yield("\nPONG")
        // No finish() — the stream stays open, exactly as a live session's does.
    }
    let value = await WebSocketHandler.nextResponse(stream)
    #expect(value == "\nPONG")
}

// MARK: - Settings panel wiring

@Test("SettingsPanel renders a hidden overlay containing the settings controls")
func settingsPanelRendersHiddenOverlay() {
    let html = SettingsPanel(isOpen: false).render()
    #expect(html.contains("id=\"settings-overlay\""))
    #expect(html.contains("style=\"display: none\""))
    // The controls the gear button is supposed to open.
    #expect(html.contains("id=\"settings-model\""))
    #expect(html.contains("id=\"settings-temp\""))
    #expect(html.contains("id=\"settings-maxtokens\""))
}

@Test("SettingsPanel renders visible when isOpen")
func settingsPanelRendersVisibleWhenOpen() {
    let html = SettingsPanel(isOpen: true).render()
    #expect(html.contains("id=\"settings-overlay\""))
    #expect(html.contains("style=\"display: flex\""))
}

@Test("chat page includes the settings overlay so the gear button is not dead")
func chatPageIncludesSettingsOverlay() {
    // The /ui chat route injects SettingsPanel via HTMLDocument's
    // `settingsHTML` parameter (rendered inside #app). Simulate that
    // composition: chat body + settings overlay, both inside the app div.
    let body = ChatPage(welcomeMessage: "hi").render()
    let settings = SettingsPanel(isOpen: false).render()
    let html = HTMLDocument(
        title: "ARC Agent",
        body: body,
        settingsHTML: settings,
        devMode: false
    ).render()
    // The gear button (in the header) and its target must coexist in the page.
    #expect(html.contains("id=\"settings-btn\""))
    #expect(html.contains("id=\"settings-overlay\""))
    #expect(html.contains("onclick=\"toggleSettings()\""))
}

// MARK: - Session lifecycle: a superseded agent must not kill its successor

@Test("superseded session agent does not tear down the new one")
func supersededAgentDoesNotTearDownSuccessor() async {
    let dm = DeliveryManager()
    let pm = ProfileManager()
    let config = SessionRegistry.AgentConfig(
        model: "gpt-4o",
        provider: "openai",
        baseURL: "https://api.openai.com/v1",
        apiKey: "test-key"
    )
    let registry = SessionRegistry(
        agentConfig: config,
        deliveryManager: dm,
        profileManager: pm
    )

    // Message #1: creates agent A1, registered under the id.
    let _ = await registry.getOrCreate(sessionID: "regress-same")
    // Message #2: finishes A1's input stream (A1 will exit its message loop)
    // and installs a NEW agent A2 under the same id.
    let _ = await registry.getOrCreate(sessionID: "regress-same")

    // A1's detached task now runs its teardown. BEFORE the fix it called an
    // identity-blind registry.remove(sessionID:) that deleted the NEW agent's
    // handle + agent and finished A2's response stream — so activeCount fell
    // to 0 and A2's response was lost ("no response from agent"). AFTER the
    // fix its removeIfCurrent(agent:) is a no-op (A2 !== A1), so A2 survives.
    //
    // Poll until the count is no longer 1 (teardown deleted the successor) or
    // the window closes (teardown was a safe no-op).
    var count = 1
    for _ in 0..<60 {
        count = await registry.activeCount
        if count != 1 { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(count == 1, "superseded agent must not tear down its successor")
}

