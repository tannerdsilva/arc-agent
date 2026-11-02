import ArcAgentCore
import Foundation
import Testing
import WebUICore
import WebUIState

@testable import ArcWebUI

/// The turn client is bound straight onto `turnClientOverride` (internal, so
/// `@testable` reaches it) — the production init fills the var from the live
/// config. A file-scope helper keeps the call sites honest about awaiting the
/// actor.
private extension AppState {
    func setTurnClient(_ client: any LLMClient) {
        turnClientOverride = client
    }
}

/// The queue drain must not eat the user's typing (audit 2026-11-01, wave 4):
/// a message queued during turn 1 runs through the drain's own `runTurn`
/// start, which unconditionally consumed whatever draft existed at drain
/// time — the text the user was typing while arc replied. The queued turn's
/// text comes from the queue, not the composer, so there is nothing to
/// consume: the draft typed during the live turn must survive the drain.
/// The direct send path keeps its consumption (the composer text IS the text
/// being sent there) — both sides pinned through the real `runTurn`, driven
/// by a scripted streaming client so no model is ever contacted.
@Suite("Queue drain draft preservation", .serialized)
struct DrainDraftPreservationTests {

    private static let sessionID = "s-drain-draft"

    /// Minimal scripted streaming client: one text chunk, then stop. An optional
    /// pause before the chunk simulates a turn that runs long enough for the
    /// user to type during it.
    private struct SingleChunkClient: LLMClient {
        let chunk: String
        var pauseMilliseconds: Int = 0

        func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
            throw LLMError.apiError(statusCode: 500, message: "scripted client is streaming-only")
        }

        func complete(
            messages: [Message],
            tools: [[String: Any]]?,
            reasoningEffort: String?
        ) async throws -> LLMResponse {
            try await complete(messages: messages, tools: tools)
        }

        func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
            stream(messages: messages, tools: tools, reasoningEffort: nil)
        }

        func stream(
            messages: [Message],
            tools: [[String: Any]]?,
            reasoningEffort: String?
        ) -> AsyncThrowingStream<LLMDelta, Error> {
            let chunk = chunk
            return AsyncThrowingStream { continuation in
                Task {
                    if pauseMilliseconds > 0 {
                        try? await Task.sleep(for: .milliseconds(pauseMilliseconds))
                    }
                    continuation.yield(LLMDelta(content: chunk))
                    continuation.yield(LLMDelta(content: nil, finishReason: "stop"))
                    continuation.finish()
                }
            }
        }
    }

    /// Fixture with a scripted turn client: the turn runs against a canned
    /// stream, never the network. `activeConfig` mirrors the streaming-dom
    /// suite's shape — `runTurn` needs an active model config to mint the
    /// turn agent.
    private static func makeFixture() -> AppState.RenderFixture {
        var f = AppState.RenderFixture()
        f.settings.modelConfigs = [ModelConfigPreset(
            name: "drain-draft",
            model: "stream-model-1",
            baseURL: "http://127.0.0.1:9/v1",
            contextLength: 8_000,
            maxOutputTokens: 512
        )]
        f.settings.activeConfig = "drain-draft"
        f.settings.workspaces = [WorkspaceEntry(name: "main", path: "/tmp")]
        f.settings.activeWorkspace = "main"
        f.arcConfig.tools.disabledToolsets = []
        f.sessions = [
            Session(id: Self.sessionID,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    title: "Drain draft",
                    messageCount: 1,
                    messages: [Message(role: .user, content: "earlier")]),
        ]
        f.activeSessionID = Self.sessionID
        f.activeTabID = "chat"
        return f
    }

    // The turn client is bound straight onto `turnClientOverride` (internal,
    // so `@testable` reaches it) — the production init fills the var from the
    // live config.

    /// Wait until no turn is active for the session — the drain spawns its
    /// turn as a fire-and-forget `Task`, so the second turn's completion is
    /// observed through state, with a deadline so a hung turn fails the test
    /// instead of hanging it.
    private func waitForQuiescence(_ app: AppState, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let turns = await app.activeTurns
            if turns[Self.sessionID] == nil { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    @Test("a draft typed during turn 1 survives the queued message's drain")
    func drainPreservesDraft() async {
        let app = AppState(renderFixture: Self.makeFixture())
        // Turn 1 streams one chunk after a pause — long enough for the user
        // to type while it runs.
        await app.setTurnClient(SingleChunkClient(chunk: "first reply", pauseMilliseconds: 300))

        // The user queues a message while turn 1 runs…
        await app.queueSend("queued message", sessionID: Self.sessionID)

        // …turn 1 starts (a direct-path send: its start consumes whatever
        // draft existed at ITS start)…
        let turn = Task {
            await app.runTurn(
                userText: "first message",
                pusher: { _ in },
                sessionID: Self.sessionID,
                selectAfter: false
            )
        }
        // …and the user types their follow-up DURING turn 1 — the engine's
        // input handler stores it through `storeComposerDraft`, the same seam.
        try? await Task.sleep(nanoseconds: 120_000_000)
        await app.storeComposerDraft("my in-progress text", sessionID: Self.sessionID)

        await turn.value
        let settled = await waitForQuiescence(app)
        #expect(settled, "the turn + its queued drain must both finish")

        // The drain turn's text came from the queue, not the composer — the
        // draft the user typed during turn 1 must still be there.
        let draft = await app.settings.composerDrafts[Self.sessionID]
        #expect(draft == "my in-progress text",
                "the drain must not consume a draft it did not send — the user's in-progress text was silently deleted")
    }

    @Test("the direct path still consumes the draft it sends")
    func directSendConsumesDraft() async {
        let app = AppState(renderFixture: Self.makeFixture())
        await app.setTurnClient(SingleChunkClient(chunk: "reply"))

        // Direct send: the composer text IS the text being sent — runTurn's
        // draft consumption (note + clear) is the existing UX-04 contract.
        await app.storeComposerDraft("hello there", sessionID: Self.sessionID)

        await app.runTurn(
            userText: "hello there",
            pusher: { _ in },
            sessionID: Self.sessionID,
            selectAfter: false
        )
        let settled = await waitForQuiescence(app)
        #expect(settled, "the turn must finish")

        let draft = await app.settings.composerDrafts[Self.sessionID]
        #expect(draft?.isEmpty != false,
                "the direct path must consume the draft it sent")
    }
}