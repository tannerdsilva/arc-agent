import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

// =========================================================================
// MARK: - Scripted streaming client

/// Scripted streaming ``LLMClient`` for turn-event tests.
///
/// Round 1 (no tool result in the history) emits `first`; every later round
/// emits `final`. Deltas arrive reasoning → content chunks → tool calls →
/// usage → finish reason, mirroring the OpenAI-compatible wire order (the
/// turn loop stops reading at `finishReason`).
struct EventScriptClient: LLMClient {

    struct Round {
        var chunks: [String] = []
        var reasoning: String? = nil
        var usage: Usage? = nil
        var toolCalls: [ToolCallDelta] = []
    }

    let first: Round
    let final: Round

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        throw LLMError.apiError(statusCode: 500, message: "scripted client is streaming-only")
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        stream(messages: messages, tools: tools, reasoningEffort: nil)
    }

    func stream(
        messages: [Message],
        tools: [[String: Any]]?,
        reasoningEffort: String?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        let round = messages.contains(where: { $0.role == .tool }) ? final : first
        return AsyncThrowingStream { continuation in
            Task {
                if let reasoning = round.reasoning, !reasoning.isEmpty {
                    continuation.yield(LLMDelta(content: nil, reasoning: reasoning))
                }
                for chunk in round.chunks {
                    continuation.yield(LLMDelta(content: chunk))
                }
                if !round.toolCalls.isEmpty {
                    continuation.yield(LLMDelta(content: nil, toolCalls: round.toolCalls))
                }
                if let usage = round.usage {
                    continuation.yield(LLMDelta(content: nil, usage: usage))
                }
                continuation.yield(LLMDelta(
                    content: nil,
                    finishReason: round.toolCalls.isEmpty ? "stop" : "tool_calls"
                ))
                continuation.finish()
            }
        }
    }
}

// =========================================================================
// MARK: - Turn event surface

/// Pins the structured turn surface: event ordering, projection parity with
/// the historic string stream, and the injected approval/clarify presenters.
///
/// Serialized: the clarify presenter lives in the process-wide
/// ``ClarifyTool/presenters`` box, so tests that install or clear it must not
/// overlap. Approval presenters are per-agent and would not need this.
@Suite("Turn event surface", .serialized)
struct TurnEventTests {

    // MARK: helpers

    private func makeAgent(
        registry: CompileTimeToolRegistry,
        httpClient: HTTPClient,
        client: any LLMClient,
        approvalMode: ApprovalMode = .manual
    ) async -> ArcAgent {
        let config = ArcAgent.Configuration(
            model: "test-model",
            provider: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "",
            registry: registry,
            skills: [],
            maxIterations: 6,
            maxTurnDuration: 30,
            persistSessions: false,
            approvalMode: approvalMode,
            query: nil,
            maxContextTokens: 64_000
        )
        let agent = ArcAgent(config: config)
        await agent.setupClient(httpClient: httpClient)
        await agent.setClient(client)
        return agent
    }

    private func collect(_ agent: ArcAgent, message: String = "go") async throws -> [AgentTurnEvent] {
        var events: [AgentTurnEvent] = []
        for try await event in agent.streamTurn(message: message) {
            events.append(event)
        }
        return events
    }

    private func textDeltas(_ events: [AgentTurnEvent]) -> [String] {
        events.compactMap { event in
            if case .textDelta(let text) = event { return text }
            return nil
        }
    }

    private func completedText(_ events: [AgentTurnEvent]) -> String? {
        for case .completed(let text) in events.reversed() {
            return text
        }
        return nil
    }

    private func toolStarted(_ events: [AgentTurnEvent]) -> [(String, String, String)] {
        events.compactMap { event in
            if case .toolCallStarted(let id, let name, let arguments) = event {
                return (id, name, arguments)
            }
            return nil
        }
    }

    private func toolFinished(_ events: [AgentTurnEvent]) -> [(String, String, String)] {
        events.compactMap { event in
            if case .toolCallFinished(let id, let name, let result) = event {
                return (id, name, result)
            }
            return nil
        }
    }

    private func stringStream(_ agent: ArcAgent, message: String = "go") async throws -> String {
        var text = ""
        for try await chunk in agent.streamConversation(message: message) {
            text += chunk
        }
        return text
    }

    // MARK: tests

    @Test("text turn streams deltas then exactly one terminal completion")
    func textTurnStreamsDeltasAndCompletes() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown(); try? httpClient.syncShutdown() }

        let client = EventScriptClient(
            first: .init(chunks: ["Hel", "lo, ", "world"]),
            final: .init()
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        let events = try await collect(agent)

        #expect(textDeltas(events) == ["Hel", "lo, ", "world"])
        #expect(completedText(events) == "Hello, world")
        let completions = events.filter { if case .completed = $0 { return true } else { return false } }
        #expect(completions.count == 1)

        // projection parity: the string stream carries exactly the visible text.
        let agent2 = await makeAgent(registry: registry, httpClient: httpClient, client: client)
        let projected = try await stringStream(agent2)
        #expect(projected == "Hello, world")
    }

    @Test("tool round emits started and finished, and the text projection re-synthesises the historic tool line")
    func toolRoundEmitsLifecycle() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown(); try? httpClient.syncShutdown() }

        let toolCall = ToolCallDelta(
            index: 0,
            id: "call_1",
            name: "terminal",
            arguments: #"{"command":"echo arc-turn-event"}"#
        )
        let client = EventScriptClient(
            first: .init(toolCalls: [toolCall]),
            final: .init(chunks: ["done"])
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        let events = try await collect(agent)

        let started = toolStarted(events)
        #expect(started.count == 1)
        #expect(started.first?.0 == "call_1")
        #expect(started.first?.1 == "terminal")
        #expect(started.first?.2.contains("echo arc-turn-event") == true)

        let finished = toolFinished(events)
        #expect(finished.count == 1)
        #expect(finished.first?.0 == "call_1")
        #expect(finished.first?.2.contains("arc-turn-event") == true)

        // ordering: started before finished; completed last.
        let names = events.map { event -> String in
            switch event {
            case .textDelta: return "text"
            case .reasoningDelta: return "reasoning"
            case .toolCallStarted: return "started"
            case .toolCallFinished: return "finished"
            case .usage: return "usage"
            case .completed: return "completed"
            case .failed: return "failed"
            }
        }
        let startedIndex = names.firstIndex(of: "started")
        let finishedIndex = names.firstIndex(of: "finished")
        #expect(startedIndex != nil && finishedIndex != nil && startedIndex! < finishedIndex!)
        #expect(names.last == "completed")

        // projection parity: the string stream still carries the tool line.
        let agent2 = await makeAgent(registry: registry, httpClient: httpClient, client: client)
        let projected = try await stringStream(agent2)
        #expect(projected.contains("[Tool: terminal]"))
        #expect(projected.contains("arc-turn-event"))
        #expect(projected.contains("done"))
    }

    @Test("reasoning and usage stream as events and never leak into the text projection")
    func reasoningAndUsageEmitted() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown(); try? httpClient.syncShutdown() }

        let usage = Usage(promptTokens: 11, completionTokens: 7, totalTokens: 18)
        let client = EventScriptClient(
            first: .init(chunks: ["answer"], reasoning: "thinking hard", usage: usage),
            final: .init()
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        let events = try await collect(agent)

        let reasoning = events.compactMap { event -> String? in
            if case .reasoningDelta(let text) = event { return text }
            return nil
        }
        #expect(reasoning == ["thinking hard"])
        let usages = events.compactMap { event -> Usage? in
            if case .usage(let reported) = event { return reported }
            return nil
        }
        #expect(usages == [usage])
        #expect(completedText(events) == "answer")

        // projection parity: reasoning is display-only.
        let agent2 = await makeAgent(registry: registry, httpClient: httpClient, client: client)
        let projected = try await stringStream(agent2)
        #expect(projected == "answer")
    }

    @Test("approval presenter: an approved dangerous command executes")
    func approvalPresenterGrantsDangerousCommand() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown(); try? httpClient.syncShutdown() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-turn-event-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = dir.appendingPathComponent("payload.txt")
        try "x".write(to: victim, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let command = "rm -rf \(dir.path)"
        let toolCall = ToolCallDelta(
            index: 0,
            id: "call_rm",
            name: "terminal",
            arguments: #"{"command":"\#(command)"}"#
        )
        let client = EventScriptClient(
            first: .init(toolCalls: [toolCall]),
            final: .init(chunks: ["removed"])
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        let recorder = PresenterRecorder()
        await agent.setApprovalPresenter { request in
            await recorder.record(request)
            return .approve
        }

        let events = try await collect(agent, message: "clean \(dir.path)")

        let requests = await recorder.requests
        #expect(requests.count == 1)
        #expect(requests.first?.command.contains("rm -rf") == true)

        let result = toolFinished(events).first?.2 ?? ""
        #expect(!result.contains("requires manual approval"))
        #expect(!FileManager.default.fileExists(atPath: victim.path), "an approved command must execute")
    }

    @Test("approval presenter: a denied dangerous command is blocked")
    func approvalPresenterDeniesDangerousCommand() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown(); try? httpClient.syncShutdown() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-turn-event-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = dir.appendingPathComponent("payload.txt")
        try "x".write(to: victim, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let command = "rm -rf \(dir.path)"
        let toolCall = ToolCallDelta(
            index: 0,
            id: "call_rm",
            name: "terminal",
            arguments: #"{"command":"\#(command)"}"#
        )
        let client = EventScriptClient(
            first: .init(toolCalls: [toolCall]),
            final: .init(chunks: ["ok"])
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        await agent.setApprovalPresenter { _ in .deny }

        let events = try await collect(agent, message: "clean \(dir.path)")

        let result = toolFinished(events).first?.2 ?? ""
        #expect(result.contains("blocked by security policy"))
        #expect(FileManager.default.fileExists(atPath: victim.path), "a denied command must not execute")
    }

    @Test("without a presenter a dangerous command reports the historic manual-approval notice")
    func approvalWithoutPresenterKeepsHistoricBehaviour() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown(); try? httpClient.syncShutdown() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-turn-event-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = dir.appendingPathComponent("payload.txt")
        try "x".write(to: victim, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let command = "rm -rf \(dir.path)"
        let toolCall = ToolCallDelta(
            index: 0,
            id: "call_rm",
            name: "terminal",
            arguments: #"{"command":"\#(command)"}"#
        )
        let client = EventScriptClient(
            first: .init(toolCalls: [toolCall]),
            final: .init(chunks: ["ok"])
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        let events = try await collect(agent, message: "clean \(dir.path)")

        let result = toolFinished(events).first?.2 ?? ""
        #expect(result.contains("requires manual approval"))
        #expect(FileManager.default.fileExists(atPath: victim.path), "an unapproved command must not execute")
    }

    @Test("clarify presenter: the human answer becomes the tool result")
    func clarifyPresenterAnswerBecomesToolResult() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown(); try? httpClient.syncShutdown() }

        let toolCall = ToolCallDelta(
            index: 0,
            id: "call_ask",
            name: "clarify",
            arguments: #"{"question":"Which number?","choices":["1","2"]}"#
        )
        let client = EventScriptClient(
            first: .init(toolCalls: [toolCall]),
            final: .init(chunks: ["picked 2"])
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        let recorder = ClarifyRecorder()
        await ClarifyTool.presenters.set { question, choices in
            await recorder.record(question: question, choices: choices)
            return "2"
        }

        let events = try await collect(agent, message: "ask me")

        let asked = await recorder.asked
        #expect(asked.count == 1)
        #expect(asked.first?.0 == "Which number?")
        #expect(asked.first?.1 == ["1", "2"])

        let result = toolFinished(events).first?.2 ?? ""
        #expect(result == "2")
        #expect(completedText(events) == "picked 2")

        // leave the ambient presenter box clean for the next serialized test.
        await ClarifyTool.presenters.set(nil)
    }

    @Test("clarify without a presenter keeps the historic unavailable error")
    func clarifyWithoutPresenterReportsUnavailable() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown(); try? httpClient.syncShutdown() }

        // deterministic: clear any presenter left by other tests first.
        await ClarifyTool.presenters.set(nil)

        let toolCall = ToolCallDelta(
            index: 0,
            id: "call_ask",
            name: "clarify",
            arguments: #"{"question":"Which number?"}"#
        )
        let client = EventScriptClient(
            first: .init(toolCalls: [toolCall]),
            final: .init(chunks: ["ok"])
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        let events = try await collect(agent, message: "ask me")

        let result = toolFinished(events).first?.2 ?? ""
        #expect(result.contains("not available in this execution context"))
    }

    @Test("always-allow from the presenter records the command and skips future prompts")
    func alwaysAllowPersistsThroughSink() async throws {
        let sink = SinkRecorder()
        let manager = ApprovalManager(mode: .manual)
        await manager.setAlwaysAllowSink { command in await sink.record(command) }
        await manager.setPresenter { _ in .alwaysAllow }

        let command = "rm -rf /tmp/arc-turn-event-never-created"
        let decision = await manager.requestApproval(
            command: command, description: "test", sessionKey: "s1"
        )
        guard case .approved = decision else {
            Issue.record("expected .approved from the alwaysAllow decision, got \(decision)")
            return
        }
        let recorded = await sink.commands
        #expect(recorded == [command])

        let needsAgain = await manager.needsApproval(command: command, sessionKey: "s1")
        #expect(needsAgain == false)
    }

    @Test("allow-session from the presenter pre-approves the session but critical commands still require approval")
    func allowSessionPreApproves() async throws {
        let manager = ApprovalManager(mode: .manual)
        await manager.setPresenter { _ in .allowSession }

        _ = await manager.requestApproval(
            command: "sudo ls", description: "test", sessionKey: "s2"
        )

        let dangerous = await manager.needsApproval(command: "rm -rf /tmp/arc-x", sessionKey: "s2")
        #expect(dangerous == false)
        let critical = await manager.needsApproval(command: "rm -rf /", sessionKey: "s2")
        #expect(critical == true)
    }
}

// =========================================================================
// MARK: - Record-keeping actors for presenter closures

/// Captures the approval requests a presenter receives.
actor PresenterRecorder {
    private(set) var requests: [ApprovalRequest] = []

    func record(_ request: ApprovalRequest) {
        requests.append(request)
    }
}

/// Captures the questions a clarify presenter receives.
actor ClarifyRecorder {
    private(set) var asked: [(String, [String])] = []

    func record(question: String, choices: [String]) {
        asked.append((question, choices))
    }
}

/// Captures always-allow sink callbacks.
actor SinkRecorder {
    private(set) var commands: [String] = []

    func record(_ command: String) {
        commands.append(command)
    }
}