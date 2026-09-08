import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

// =========================================================================
// MARK: - Scripted LLM client (thread-safe via lock-protected box)
//
// The recorded calls are accumulated in a lock-protected `@unchecked
// Sendable` box, matching the established pattern for Swift-Testing mocks
// that are mutated from `@Sendable`/stream contexts.
// =========================================================================

final class ClientScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [LLMResponse]
    private var streamScripts: [[LLMDelta]]
    private var calls: [[Message]] = []

    init(responses: [LLMResponse], streamScripts: [[LLMDelta]] = []) {
        self.responses = responses
        self.streamScripts = streamScripts
    }

    func nextResponse(messages: [Message]) -> LLMResponse {
        lock.lock(); defer { lock.unlock() }
        calls.append(messages)
        if responses.isEmpty { return LLMResponse(content: "done", finishReason: "stop") }
        return responses.removeFirst()
    }

    func nextStreamScript(messages: [Message]) -> [LLMDelta] {
        lock.lock(); defer { lock.unlock() }
        calls.append(messages)
        if streamScripts.isEmpty { return [] }
        return streamScripts.removeFirst()
    }

    func recordedCalls() -> [[Message]] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

struct ScriptedClient: LLMClient {
    let box: ClientScripts

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        box.nextResponse(messages: messages)
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        let script = box.nextStreamScript(messages: messages)
        return AsyncThrowingStream { continuation in
            Task {
                for delta in script {
                    continuation.yield(delta)
                }
                continuation.finish()
            }
        }
    }
}

/// Tracks the maximum number of concurrently executing tool handlers.
actor ConcurrencyTracker {
    private var current = 0
    private var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func exit() { current -= 1 }
    func maxConcurrent() -> Int { peak }
}

/// A session store whose reads fail — proves restore failures never fail a turn.
private struct FailingGetStore: SessionStore {
    let inner: FileSessionStore
    func create(_ session: Session) async throws { try await inner.create(session) }
    func get(id: String) async throws -> Session? { throw SessionError.storageError("boom") }
    func update(_ session: Session) async throws { try await inner.update(session) }
    func delete(id: String) async throws { try await inner.delete(id: id) }
    func list(limit: Int) async throws -> [Session] { try await inner.list(limit: limit) }
    func appendMessage(sessionID: String, message: Message) async throws {
        try await inner.appendMessage(sessionID: sessionID, message: message)
    }
}

// =========================================================================
// MARK: - Suite
// =========================================================================

@Suite("Prompt Hardening")
struct PromptHardeningTests {

    private func makeAgent(
        registry: CompileTimeToolRegistry,
        httpClient: HTTPClient,
        store: any SessionStore = FileSessionStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-prompt-hardening-\(UUID().uuidString)")
        ),
        sessionID: String? = nil,
        persistSessions: Bool = true,
        client: ScriptedClient
    ) async -> ArcAgent {
        let config = ArcAgent.Configuration(
            model: "test-model",
            provider: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "sk-test",
            registry: registry,
            sessionStore: store,
            memoryProvider: nil,
            skills: [],
            maxIterations: 10,
            maxTurnDuration: 30,
            persistSessions: persistSessions,
            approvalMode: .off,
            query: nil,
            maxContextTokens: 64_000,
            sessionID: sessionID
        )
        let agent = ArcAgent(config: config)
        await agent.setupClient(httpClient: httpClient)
        await agent.setClient(client)
        return agent
    }

    private func readFileEntry(_ handler: @escaping @Sendable ([String: Any]) async throws -> String) -> ToolEntry {
        ToolEntry(
            name: "read_file",
            toolset: "file",
            description: "test read tool",
            schema: .object(properties: ["path": .string(description: "path")], required: ["path"]),
            handler: handler
        )
    }

    // MARK: - Planner

    @Test("planner groups parallel-safe runs and isolates barriers")
    func plannerSegments() {
        func call(_ name: String, _ id: String) -> ToolCall {
            ToolCall(id: id, function: ToolCallFunction(name: name, arguments: "{}"))
        }
        let batch = [
            call("read_file", "1"), call("web_search", "2"), call("terminal", "3"),
            call("read_file", "4"), call("read_file", "5"), call("write_file", "6"),
        ]
        let segments = ArcAgent.planToolBatch(batch)
        #expect(segments.map { $0.map(\.id) } == [["1", "2"], ["3"], ["4", "5"], ["6"]],
            "expected parallel run, barrier, parallel run, barrier; got \(segments.map { $0.map(\.id) })")
    }

    // MARK: - Session restore

    @Test("sessionID restores persisted history before the first turn")
    func restoreLoadsHistory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arc-restore-\(UUID().uuidString)")
        let store = FileSessionStore(directory: dir)
        let sid = "restore-me"
        try await store.create(Session(id: sid, model: "m", provider: "p", messages: [
            Message(role: .user, content: "old user"),
            Message(role: .assistant, content: "old answer"),
        ]))

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let box = ClientScripts(responses: [LLMResponse(content: "new answer", finishReason: "stop")])
        let agent = await makeAgent(
            registry: CompileTimeToolRegistry(),
            httpClient: httpClient,
            store: store,
            sessionID: sid,
            client: ScriptedClient(box: box)
        )

        let out = try await agent.runConversation(message: "new user")
        #expect(out == "new answer")

        // The LLM must have seen the restored history, exactly once each.
        let firstCall = box.recordedCalls().first
        #expect(firstCall != nil, "expected at least one recorded call")
        guard let sent = firstCall else { return }
        #expect(sent.filter { $0.role == .user }.map(\.content) == ["old user", "new user"])
        #expect(sent.contains { $0.role == .assistant && $0.content == "old answer" })
        #expect(sent.filter { $0.role == .user }.count == 2, "restored history must not be duplicated")

        // Persistence appends only the NEW messages (user + assistant).
        let stored = try await store.get(id: sid)
        #expect(stored?.messages.count == 4)
    }

    @Test("restore is one-shot: the second turn does not re-read or duplicate history")
    func restoreIsOneShot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arc-restore-once-\(UUID().uuidString)")
        let store = FileSessionStore(directory: dir)
        let sid = "restore-once"
        try await store.create(Session(id: sid, messages: [Message(role: .user, content: "old")]))

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let box = ClientScripts(responses: [
            LLMResponse(content: "a", finishReason: "stop"),
            LLMResponse(content: "b", finishReason: "stop"),
        ])
        let agent = await makeAgent(
            registry: CompileTimeToolRegistry(),
            httpClient: httpClient,
            store: store,
            sessionID: sid,
            client: ScriptedClient(box: box)
        )

        _ = try await agent.runConversation(message: "q1")
        _ = try await agent.runConversation(message: "q2")

        let calls = box.recordedCalls()
        #expect(calls.count == 2)
        #expect(calls[1].filter { $0.role == .user }.map(\.content) == ["old", "q1", "q2"],
            "history across turns must be continuous, not duplicated")
    }

    @Test("a failing session read never fails the turn")
    func restoreFailureIsNonFatal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arc-restore-fail-\(UUID().uuidString)")
        let store = FailingGetStore(inner: FileSessionStore(directory: dir))

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let box = ClientScripts(responses: [LLMResponse(content: "survived", finishReason: "stop")])
        let agent = await makeAgent(
            registry: CompileTimeToolRegistry(),
            httpClient: httpClient,
            store: store,
            sessionID: "will-fail",
            client: ScriptedClient(box: box)
        )

        let out = try await agent.runConversation(message: "hello")
        #expect(out == "survived", "restore failure must not fail the turn")
    }

    // MARK: - Parallel tool execution

    @Test("parallel-safe batch executes concurrently and preserves result order")
    func parallelBatchRunsConcurrentlyAndInOrder() async throws {
        let tracker = ConcurrencyTracker()
        var registry = CompileTimeToolRegistry()
        try registry.register(readFileEntry { args in
            let path = args["path"] as? String ?? "?"
            await tracker.enter()
            try? await Task.sleep(nanoseconds: path == "slow" ? 120_000_000 : 20_000_000)
            await tracker.exit()
            return "R:\(path)"
        })
        try registry.register(ToolEntry(
            name: "web_search",
            toolset: "web",
            description: "test search tool",
            schema: .object(properties: ["query": .string(description: "query")], required: ["query"]),
            handler: { args in
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 10_000_000)
                await tracker.exit()
                return "W:\(args["query"] as? String ?? "?")"
            }
        ))

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let box = ClientScripts(responses: [
            LLMResponse(content: nil, toolCalls: [
                ToolCall(id: "c1", function: ToolCallFunction(name: "read_file", arguments: #"{"path":"slow"}"#)),
                ToolCall(id: "c2", function: ToolCallFunction(name: "web_search", arguments: #"{"query":"fast"}"#)),
            ], finishReason: "tool_calls"),
            LLMResponse(content: "done", finishReason: "stop"),
        ])
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: ScriptedClient(box: box))

        let out = try await agent.runConversation(message: "go")
        #expect(out == "done")
        let peak = await tracker.maxConcurrent()
        #expect(peak >= 2, "parallel-safe calls must overlap (peak \(peak))")

        let secondCall = box.recordedCalls()[1]
        let toolMsgs = secondCall.filter { $0.role == .tool }
        #expect(toolMsgs.map(\.toolCallID) == ["c1", "c2"], "tool results must keep emission order")
        #expect(toolMsgs.map(\.content) == ["R:slow", "W:fast"])
    }

    // MARK: - Recoveries (non-streaming)

    @Test("empty response after tool results gets a bounded nudge, then answers")
    func emptyAfterToolsRecovers() async throws {
        var registry = CompileTimeToolRegistry()
        try registry.register(readFileEntry { _ in "content-1" })

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let box = ClientScripts(responses: [
            LLMResponse(content: nil, toolCalls: [
                ToolCall(id: "c1", function: ToolCallFunction(name: "read_file", arguments: #"{"path":"x"}"#)),
            ], finishReason: "tool_calls"),
            LLMResponse(content: "   ", finishReason: "stop"),
            LLMResponse(content: "final answer", finishReason: "stop"),
        ])
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: ScriptedClient(box: box))

        let out = try await agent.runConversation(message: "go")
        #expect(out == "final answer")
        #expect(box.recordedCalls().count == 3)
        #expect(box.recordedCalls()[2].contains {
            $0.role == .system && ($0.content ?? "").contains("tool results above")
        }, "expected the empty-after-tools nudge in the third call")
    }

    @Test("finish_reason tool_calls with no calls nudges, then answers")
    func emptyToolCallsRecovers() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let box = ClientScripts(responses: [
            LLMResponse(content: nil, toolCalls: [], finishReason: "tool_calls"),
            LLMResponse(content: "ok then", finishReason: "stop"),
        ])
        let agent = await makeAgent(
            registry: CompileTimeToolRegistry(),
            httpClient: httpClient,
            client: ScriptedClient(box: box)
        )

        let out = try await agent.runConversation(message: "go")
        #expect(out == "ok then")
        #expect(box.recordedCalls().count == 2)
        #expect(box.recordedCalls()[1].contains {
            $0.role == .system && ($0.content ?? "").contains("did not specify any")
        }, "expected the empty-tool-calls nudge in the second call")
    }

    @Test("truncated output continues instead of being lost")
    func truncationContinues() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let box = ClientScripts(responses: [
            LLMResponse(content: "PART ONE ", finishReason: "length"),
            LLMResponse(content: "PART TWO", finishReason: "stop"),
        ])
        let agent = await makeAgent(
            registry: CompileTimeToolRegistry(),
            httpClient: httpClient,
            client: ScriptedClient(box: box)
        )

        let out = try await agent.runConversation(message: "go")
        #expect(out == "PART TWO")
        let second = box.recordedCalls()[1]
        #expect(second.contains { $0.role == .assistant && $0.content == "PART ONE " },
            "the partial answer must be carried forward for the model to continue")
        #expect(second.contains { $0.role == .system && ($0.content ?? "").contains("truncated") },
            "expected the truncation continuation nudge")
    }

    // MARK: - Recoveries (streaming path)

    @Test("streaming: empty-after-tools nudges then answers on the stream path")
    func streamingEmptyAfterToolsRecovers() async throws {
        var registry = CompileTimeToolRegistry()
        try registry.register(readFileEntry { _ in "content-1" })

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let box = ClientScripts(responses: [], streamScripts: [
            [LLMDelta(content: nil, toolCalls: [
                ToolCallDelta(index: 0, id: "c1", name: "read_file", arguments: #"{"path":"x"}"#),
            ])],
            [LLMDelta(content: "   ")],
            [LLMDelta(content: "stream-final")],
        ])
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: ScriptedClient(box: box))

        let stream = await agent.streamConversation(message: "go")
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        #expect(chunks.joined().contains("stream-final"))
        #expect(box.recordedCalls().count == 3)
        #expect(box.recordedCalls()[2].contains {
            $0.role == .system && ($0.content ?? "").contains("tool results above")
        }, "expected the empty-after-tools nudge on the stream path")
    }
}
