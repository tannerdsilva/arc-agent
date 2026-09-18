import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - Session lifecycle: a superseded agent must not kill its successor
//
// Formerly in WebSocketHandlerTests.swift; kept because it guards a real
// SessionRegistry regression (not web-UI-specific).
// =========================================================================

@Test("superseded session agent does not tear down the new one")
func supersededAgentDoesNotTearDownSuccessorViaRegistry() async {
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
    // With sequential supersede (getOrCreate awaits the predecessor's exit),
    // A2 only starts after A1 has fully torn down, so it also never contends
    // with A1's LMDB environment.
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
