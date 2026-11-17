import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

// =========================================================================
// Session-less (`--ephemeral`) mechanic.
//
// `persistSessions: false` is the agent-level switch behind the CLI's
// `arc chat --ephemeral`: the turn runs with the full tool surface but the
// session store must never be touched — no `create` (the only place a
// session record is born), no appends, no compaction commits. Hermes
// parity: `_persist_disabled` ("Hard-stop before any DB touch").
// =========================================================================

private actor EphemeralProbeStore: SessionStore {
    var creations = 0
    var appends = 0
    var updates = 0

    func create(_ session: Session) async throws { creations += 1 }
    func get(id: String) async throws -> Session? { nil }
    func update(_ session: Session) async throws { updates += 1 }
    func delete(id: String) async throws {}
    func list(limit: Int, offset: Int) async throws -> [Session] { [] }
    func appendMessage(sessionID: String, message: Message) async throws { appends += 1 }
}

private struct EphemeralTextLLM: LLMClient {
    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        LLMResponse(content: "ok-done", toolCalls: nil, finishReason: "stop", usage: nil)
    }
    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

extension ArcCoreTestRoot {
    @Suite("Ephemeral sessions", .serialized)
    struct EphemeralSessionTests {

        private func makeAgent(store: EphemeralProbeStore, httpClient: HTTPClient) async -> ArcAgent {
            let config = ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "test-key",
                registry: CompileTimeToolRegistry(),
                sessionStore: store,
                skills: [],
                maxIterations: 3,
                maxTurnDuration: 30,
                persistSessions: false,
                approvalMode: .off,
                query: nil,
                maxContextTokens: 64_000
            )
            let agent = ArcAgent(config: config)
            await agent.setupClient(httpClient: httpClient)
            await agent.setClient(EphemeralTextLLM())
            return agent
        }

        @Test("ephemeral run: the session store is never written")
        func storeNeverTouched() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }
            let store = EphemeralProbeStore()
            let agent = await makeAgent(store: store, httpClient: httpClient)

            // Two turns: the second would append if persistence were on.
            _ = try await agent.runConversation(message: "first")
            _ = try await agent.runConversation(message: "second")

            let creations = await store.creations
            let appends = await store.appends
            let updates = await store.updates
            #expect(creations == 0, "ephemeral runs must never create a session record")
            #expect(appends == 0, "ephemeral runs must never append a message")
            #expect(updates == 0, "ephemeral runs must never update a session")
        }

        @Test("ephemeral run still produces a real answer")
        func answerStillReturns() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }
            let store = EphemeralProbeStore()
            let agent = await makeAgent(store: store, httpClient: httpClient)

            let reply = try await agent.runConversation(message: "hello")
            #expect(reply.contains("ok-done"), "the turn must complete normally")
        }
    }
}
