import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

// =========================================================================
// C1 — TelegramAdapter must contain poll failures (a transient Telegram
// network error must never propagate out of the service loop and take the
// whole gateway down: ServiceGroup default failure behavior cancels all).
// =========================================================================

@Suite("Telegram adapter poll containment")
struct TelegramAdapterPollContainmentTests {

    @Test("run() survives a refused/erroring Telegram endpoint until cancelled")
    func pollErrorsAreContained() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown() }

        // Port 1 refuses connections: every getUpdates/getMe fails instantly.
        let adapter = TelegramAdapter(
            botToken: "test:token",
            allowAllUsers: true,
            pollInterval: .milliseconds(100),
            httpClient: httpClient,
            baseURLOverride: "http://127.0.0.1:1"
        )

        let task = Task { try await adapter.run() }
        try await Task.sleep(for: .seconds(1.5))
        task.cancel()
        let result = await task.result

        // CancellationError is the expected clean exit; ANY other failure
        // (i.e. an unhandled poll error escaping run()) is a regression.
        if case .failure(let error) = result, !(error is CancellationError) {
            Issue.record("run() propagated a poll error: \(error)")
        }
    }
}

// =========================================================================
// M1 — Total-duration budget on streams (maxTurnDuration was ignored on the
// streaming path; IdleTimeoutStream only bounds inter-delta silence).
// =========================================================================

@Suite("Stream total-duration watchdog")
struct StreamTotalDurationTests {

    private func trickleSource() -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream { continuation in
            Task {
                while !Task.isCancelled {
                    continuation.yield(1)
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
        }
    }

    @Test("a trickling stream (never idle enough) still hits the total budget")
    func tricklingStreamHitsTotalBudget() async throws {
        let wrapped = IdleTimeoutStream(trickleSource(), idleSeconds: 10, totalSeconds: 0.4)
        let started = Date()
        var drained = 0
        do {
            for try await _ in wrapped { drained += 1 }
            Issue.record("expected StreamTotalTimeoutError, got clean completion")
        } catch is StreamTotalTimeoutError {
            // expected — total budget enforced
        }
        #expect(drained > 0, "the source should have produced elements")
        #expect(Date().timeIntervalSince(started) < 3, "total budget must fire promptly, not after the idle budget")
    }

    @Test("no totalSeconds keeps idle-only behaviour (control)")
    func nilTotalKeepsIdleOnly() async throws {
        // Source emits one element then closes cleanly: no timeout of any kind.
        let source = AsyncThrowingStream<Int, Error> { $0.yield(1); $0.finish() }
        let wrapped = IdleTimeoutStream(source, idleSeconds: 5, totalSeconds: nil)
        var count = 0
        for try await _ in wrapped { count += 1 }
        #expect(count == 1)
    }
}

// =========================================================================
// M2 — Session persistence must advance its watermark only after a message
// actually landed; otherwise a transient store failure silently drops or
// duplicates history forever.
// =========================================================================

private enum StoreError: Error { case boom }

private actor RecordedStore: SessionStore {
    var created = 0
    var creations: Int { created }
    var appended: [Message.Role] = []
    var appendCalls = 0
    var failCreations = 0
    var failAppendAt: [Int] = []

    func failCreates_set(_ n: Int) { failCreations = n }
    func failAppendAt_set(_ list: [Int]) { failAppendAt = list }

    func create(_ session: Session) async throws {
        created += 1
        if created <= failCreations { throw StoreError.boom }
        // Session.create carries the message slice; record it like the store
        // would (TesseraSessionStore publishes the embedded messages).
        appended.append(contentsOf: session.messages.map(\.role))
    }
    func get(id: String) async throws -> Session? { nil }
    func update(_ session: Session) async throws {}
    func delete(id: String) async throws {}
    func list(limit: Int, offset: Int) async throws -> [Session] { [] }
    func appendMessage(sessionID: String, message: Message) async throws {
        appendCalls += 1
        if failAppendAt.contains(appendCalls) { throw StoreError.boom }
        appended.append(message.role)
    }
}

private struct StaticTextLLM: LLMClient {
    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        LLMResponse(content: "ok-done", toolCalls: nil, finishReason: "stop", usage: nil)
    }
    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Session persistence watermark")
struct PersistenceWatermarkTests {

    private func makeAgent(store: RecordedStore, httpClient: HTTPClient) async -> ArcAgent {
        let config = ArcAgent.Configuration(
            model: "test-model",
            provider: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "k",
            registry: CompileTimeToolRegistry(),
            sessionStore: store,
            skills: [],
            maxIterations: 3,
            maxTurnDuration: 30,
            persistSessions: true,
            approvalMode: .off,
            query: nil,
            maxContextTokens: 64_000
        )
        let agent = ArcAgent(config: config)
        await agent.setupClient(httpClient: httpClient)
        await agent.setClient(StaticTextLLM())
        return agent
    }

    @Test("partial append failure: no gap, no duplicates, resume lands every message")
    func partialAppendFailureResumes() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown() }
        let store = RecordedStore()
        // Turn 1 creates the session (carrying u1+a1). Turn 2 appends u2 (ok)
        // then a2 (fails on the 2nd append call). Turn 3 must re-attempt a2
        // before u3/a3 — no gap, no duplicate.
        await store.failAppendAt_set([2])
        let agent = await makeAgent(store: store, httpClient: httpClient)

        _ = try await agent.runConversation(message: "first")
        _ = try await agent.runConversation(message: "second")
        _ = try await agent.runConversation(message: "third")

        let roles = await store.appended
        let calls = await store.appendCalls
        let creations = await store.creations
        #expect(roles == [.user, .assistant, .user, .assistant, .user, .assistant],
                "expected exactly one append per message, got \(roles)")
        #expect(calls == 5, "expected 5 append attempts (u2, a2×2 after retry, u3, a3), got \(calls)")
        #expect(creations == 1, "session must be created exactly once")
    }

    @Test("failed session create is retried, not silently abandoned")
    func failedCreateIsRetried() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown() }
        let store = RecordedStore()
        await store.failCreates_set(1)
        let agent = await makeAgent(store: store, httpClient: httpClient)

        _ = try await agent.runConversation(message: "first")
        _ = try await agent.runConversation(message: "second")

        let creations = await store.creations
        let appended = await store.appended
        #expect(creations == 2, "create must be retried after failure")
        #expect(appended.count == 4, "all four messages must persist after the store recovers, got \(appended.count)")
    }
}

// =========================================================================
// M3 — Approval gate scope: process-executing tools (terminal, execute_code)
// must be gated; read-only tools must not.
// =========================================================================

@Suite("Approval gate scope")
struct ApprovalGateScopeTests {

    @Test("process-execution tools require approval")
    func processToolsAreGated() {
        #expect(ArcAgent.requiresApprovalForTool(named: "terminal"))
        #expect(ArcAgent.requiresApprovalForTool(named: "execute_code"))
    }

    @Test("read-only tools are not gated")
    func readToolsAreNotGated() {
        #expect(!ArcAgent.requiresApprovalForTool(named: "read_file"))
        #expect(!ArcAgent.requiresApprovalForTool(named: "search_files"))
        #expect(!ArcAgent.requiresApprovalForTool(named: "skills_list"))
    }

    @Test("dangerous patterns inside an execute_code payload still escalate in smart mode")
    func dangerousInsideCodePayloadEscalates() async {
        let manager = ApprovalManager(mode: .smart)
        // `rm -rf /tmp/x` is .dangerous and must escalate to review even
        // though it is embedded in a JSON code payload (the detector's
        // anchored critical pattern only matches bare `rm -rf /`).
        let payload = #"{"code": "import os; os.system('rm -rf /tmp/x')"}"#
        let needs = await manager.needsApproval(command: payload, sessionKey: "s")
        #expect(needs)
        let decision = await manager.requestApproval(command: payload, description: "Execute Python code", sessionKey: "s")
        guard case .requiresReview = decision else {
            Issue.record("expected .requiresReview, got \(decision)")
            return
        }
    }
}
