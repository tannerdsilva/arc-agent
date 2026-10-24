import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient
import Synchronization

// =========================================================================
// MARK: - Scripted streaming client

/// Scripted streaming ``LLMClient`` for turn-event tests.
///
/// Round 1 (no tool result in the history) emits `first`; every later round
/// emits `final`. Deltas arrive reasoning → content chunks → tool calls →
/// usage → finish reason, mirroring the OpenAI-compatible wire order (the
/// turn loop stops reading at `finishReason`).
///
/// Every `stream(...)` call's messages are recorded in call order so tests can
/// assert on what the mock provider received. `onRoundStart` runs inside the
/// emitting task *before* the first delta of a call, which lets a test act
/// mid-turn (steer, interrupt) with a happens-before edge on the next delta.
final class EventScriptClient: LLMClient {

    struct Round {
        var chunks: [String] = []
        var reasoning: String? = nil
        var usage: Usage? = nil
        var toolCalls: [ToolCallDelta] = []
    }

    let first: Round
    let final: Round

    private let onRoundStart: (@Sendable (Int) async -> Void)?
    private let recorded = Mutex<[[Message]]>([])

    init(
        first: Round,
        final: Round,
        onRoundStart: (@Sendable (Int) async -> Void)? = nil
    ) {
        self.first = first
        self.final = final
        self.onRoundStart = onRoundStart
    }

    /// Messages received by each `stream(...)` call, in call order.
    var allRecordedMessages: [[Message]] {
        recorded.withLock { Array($0) }
    }

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
        let callIndex = recorded.withLock { store -> Int in
            store.append(messages)
            return store.count - 1
        }
        let round = messages.contains(where: { $0.role == .tool }) ? final : first
        let hook = onRoundStart
        return AsyncThrowingStream { continuation in
            Task {
                await hook?(callIndex)
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

extension ArcCoreTestRoot {
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
            approvalMode: ApprovalMode = .manual,
            initialHistory: [Message]? = nil
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
                maxContextTokens: 64_000,
                initialHistory: initialHistory
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

        private func completedText(_ events: [AgentTurnEvent]) -> (text: String, reason: String?)? {
            for case .completed(let text, let reason) in events.reversed() {
                return (text, reason)
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
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let client = EventScriptClient(
                first: .init(chunks: ["Hel", "lo, ", "world"]),
                final: .init()
            )
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

            let events = try await collect(agent)

            #expect(textDeltas(events) == ["Hel", "lo, ", "world"])
            #expect(completedText(events)?.text == "Hello, world")
            let completions = events.filter { if case .completed = $0 { return true } else { return false } }
            #expect(completions.count == 1)

            // projection parity: the string stream carries exactly the visible text.
            let agent2 = await makeAgent(registry: registry, httpClient: httpClient, client: client)
            let projected = try await stringStream(agent2)
            #expect(projected == "Hello, world")
        }

        @Test("tool round emits started and finished, and the text projection re-synthesises the historic tool line")
        func toolRoundEmitsLifecycle() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

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
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

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
            #expect(completedText(events)?.text == "answer")

            // projection parity: reasoning is display-only.
            let agent2 = await makeAgent(registry: registry, httpClient: httpClient, client: client)
            let projected = try await stringStream(agent2)
            #expect(projected == "answer")
        }

        @Test("approval presenter: an approved dangerous command executes")
        func approvalPresenterGrantsDangerousCommand() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

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
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

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
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

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
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

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
            // clarify is on the default surface now; the presenter seam is what
            // this test opts into.
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
            #expect(completedText(events)?.text == "picked 2")

            // leave the ambient presenter box clean for the next serialized test.
            await ClarifyTool.presenters.set(nil)
        }

        @Test("clarify without a presenter keeps the historic unavailable error")
        func clarifyWithoutPresenterReportsUnavailable() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

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
            // clarify is on the default surface; the unavailable-error path runs
            // when no presenter is installed.
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

        // MARK: convergence A1 — history seed and public turn control

        @Test("configuration initial history reaches the first request once, ahead of the new user message")
        func initialHistorySeedsTheFirstRequestOnce() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let seeded = [
                Message(role: .user, content: "earlier question"),
                Message(role: .assistant, content: "earlier answer"),
            ]
            let client = EventScriptClient(
                first: .init(chunks: ["ok"]),
                final: .init(chunks: ["ok"])
            )
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let agent = await makeAgent(
                registry: registry,
                httpClient: httpClient,
                client: client,
                initialHistory: seeded
            )

            _ = try await collect(agent)
            _ = try await collect(agent)

            let calls = client.allRecordedMessages
            #expect(calls.count == 2)

            // first request: system, the two seeded messages in order, then the turn's user message.
            let firstTurn = calls[0].map { $0.content ?? "" }
            #expect(calls[0].first?.role == .system)
            #expect(firstTurn.count == 4)
            #expect(firstTurn[1] == "earlier question")
            #expect(firstTurn[2] == "earlier answer")
            #expect(firstTurn[3] == "go")

            // one-shot: the second turn carries the seeds exactly once, not twice.
            let secondTurn = calls[1].map { $0.content ?? "" }
            #expect(secondTurn.filter { $0 == "earlier question" }.count == 1)
            #expect(secondTurn.filter { $0 == "earlier answer" }.count == 1)
            #expect(secondTurn.filter { $0 == "go" }.count == 2)
        }

        @Test("a mid-turn steer lands after the tool result and rides the next request")
        func steerLandsAtTheToolBoundary() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let box = TurnAgentBox()
            let toolCall = ToolCallDelta(
                index: 0,
                id: "call_steer",
                name: "terminal",
                arguments: #"{"command":"echo arc-steer"}"#
            )
            let client = EventScriptClient(
                first: .init(toolCalls: [toolCall]),
                final: .init(chunks: ["done"]),
                onRoundStart: { index in
                    // mid-turn: the steer arrives while the first response streams.
                    if index == 0 { await box.steer("focus on the failing test") }
                }
            )
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)
            await box.hold(agent)

            let events = try await collect(agent)

            let calls = client.allRecordedMessages
            #expect(calls.count == 2)
            let second = calls[1]
            let toolIndex = second.firstIndex { $0.role == .tool }
            let steerIndex = second.firstIndex { ($0.content ?? "").contains("[steer:") }
            #expect(toolIndex != nil)
            #expect(steerIndex != nil)
            if let toolIndex, let steerIndex {
                #expect(steerIndex > toolIndex)
                #expect(second[steerIndex].content == "[steer: focus on the failing test]")
                #expect(steerIndex == second.count - 1)
            }
            #expect(completedText(events)?.text == "done")
        }

        @Test("interruptTurn yields the interrupt text then completed, and the same agent runs a clean second turn")
        func interruptTurnEndsTheTurnAndTheAgentRecovers() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let box = TurnAgentBox()
            let toolCall = ToolCallDelta(
                index: 0,
                id: "call_interrupt",
                name: "terminal",
                arguments: #"{"command":"echo arc-interrupt"}"#
            )
            let client = EventScriptClient(
                first: .init(toolCalls: [toolCall]),
                final: .init(chunks: ["clean"]),
                onRoundStart: { index in
                    // mid-turn: the stop arrives while the first response streams.
                    if index == 0 { await box.interrupt() }
                }
            )
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)
            await box.hold(agent)

            let interrupted = try await collect(agent)

            #expect(textDeltas(interrupted) == ["Interrupted by user."])
            #expect(completedText(interrupted)?.text == "Interrupted by user.")
            let completions = interrupted.filter { if case .completed = $0 { return true } else { return false } }
            #expect(completions.count == 1)
            // the interrupt is honoured at the iteration boundary — the second
            // request is never issued.
            #expect(client.allRecordedMessages.count == 1)

            // the same instance recovers: a clean next turn with no interrupt state left over.
            let second = try await collect(agent)
            #expect(textDeltas(second) == ["clean"])
            #expect(completedText(second)?.text == "clean")
            #expect(client.allRecordedMessages.count == 2)
        }

    // MARK: convergence A3 — per-turn clarify presenter and dispatcher

    @Test("two concurrent agents with different clarify presenters do not cross-talk")
    func concurrentClarifyPresentersDoNotCrossTalk() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { _ = httpClient.shutdown() }

        // No process-wide presenter is installed, so the TaskLocal is the
        // only rung in play.
        await ClarifyTool.presenters.set(nil)

        let askA = ToolCallDelta(
            index: 0,
            id: "call_ask_a",
            name: "clarify",
            arguments: #"{"question":"Agent A's question","choices":["a1","a2"]}"#
        )
        let askB = ToolCallDelta(
            index: 0,
            id: "call_ask_b",
            name: "clarify",
            arguments: #"{"question":"Agent B's question","choices":["b1","b2"]}"#
        )

        let clientA = EventScriptClient(
            first: .init(toolCalls: [askA]),
            final: .init(chunks: ["A answered"])
        )
        let clientB = EventScriptClient(
            first: .init(toolCalls: [askB]),
            final: .init(chunks: ["B answered"])
        )

        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agentA = await makeAgent(registry: registry, httpClient: httpClient, client: clientA)
        let agentB = await makeAgent(registry: registry, httpClient: httpClient, client: clientB)

        // Each agent installs its own presenter into its TaskLocal scope.
        await agentA.setClarifyPresenter { question, _ in
            #expect(question == "Agent A's question")
            return "a1"
        }
        await agentB.setClarifyPresenter { question, _ in
            #expect(question == "Agent B's question")
            return "b1"
        }

        // Run both turns concurrently; neither should observe the other's
        // question or answer because the TaskLocal is per-turn.
        async let eventsA = collect(agentA, message: "ask")
        async let eventsB = collect(agentB, message: "ask")
        let (evA, evB) = try await (eventsA, eventsB)

        let resultA = toolFinished(evA).first?.2 ?? ""
        let resultB = toolFinished(evB).first?.2 ?? ""
        #expect(resultA == "a1", "agent A should see its own answer")
        #expect(resultB == "b1", "agent B should see its own answer")
        #expect(completedText(evA)?.text == "A answered")
        #expect(completedText(evB)?.text == "B answered")

        // Leave the process-wide box clean for the next serialized test.
        await ClarifyTool.presenters.set(nil)
    }

    @Test("clarify resolution order: task local wins over process-wide box")
    func clarifyResolutionOrderTaskLocalWins() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { _ = httpClient.shutdown() }

        // Install the fallback-box presenter (rung 2).
        let boxRecorder = ClarifyRecorder()
        await ClarifyTool.presenters.set { question, choices in
            await boxRecorder.record(question: question, choices: choices)
            return "from-box"
        }
        defer { Task { await ClarifyTool.presenters.set(nil) } }

        let ask = ToolCallDelta(
            index: 0,
            id: "call_ask",
            name: "clarify",
            arguments: #"{"question":"Which number?","choices":["1","2"]}"#
        )
        let client = EventScriptClient(
            first: .init(toolCalls: [ask]),
            final: .init(chunks: ["done"])
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        // Agent installs a TaskLocal presenter (rung 1) that shadows the box.
        await agent.setClarifyPresenter { question, choices in
            #expect(question == "Which number?")
            #expect(choices == ["1", "2"])
            return "from-tasklocal"
        }

        let events = try await collect(agent, message: "ask me")
        let result = toolFinished(events).first?.2 ?? ""
        #expect(result == "from-tasklocal", "task local presenter must win over the box")

        let boxAsked = await boxRecorder.asked
        #expect(boxAsked.isEmpty, "the box presenter must not fire when a task local is present")
    }

    @Test("clarify resolution order: process-wide box is the fallback when no task local")
    func clarifyResolutionOrderBoxFallsBack() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { _ = httpClient.shutdown() }

        await ClarifyTool.presenters.set(nil)
        defer { await ClarifyTool.presenters.set(nil) }

        let boxRecorder = ClarifyRecorder()
        await ClarifyTool.presenters.set { question, choices in
            await boxRecorder.record(question: question, choices: choices)
            return "from-box"
        }

        let ask = ToolCallDelta(
            index: 0,
            id: "call_ask",
            name: "clarify",
            arguments: #"{"question":"Which number?","choices":["1","2"]}"#
        )
        let client = EventScriptClient(
            first: .init(toolCalls: [ask]),
            final: .init(chunks: ["done"])
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)
        // No task-local presenter set — the box is the fallback rung.

        let events = try await collect(agent, message: "ask me")
        let result = toolFinished(events).first?.2 ?? ""
        #expect(result == "from-box", "the box presenter must answer when no task local is set")
        let boxAsked = await boxRecorder.asked
        #expect(boxAsked.count == 1)
        #expect(boxAsked.first?.0 == "Which number?")
    }

    @Test("clarify resolution order: neither rung reports the historic unavailable error")
    func clarifyResolutionOrderNeitherRungErrors() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { _ = httpClient.shutdown() }

        await ClarifyTool.presenters.set(nil)

        let ask = ToolCallDelta(
            index: 0,
            id: "call_ask",
            name: "clarify",
            arguments: #"{"question":"Which number?"}"#
        )
        let client = EventScriptClient(
            first: .init(toolCalls: [ask]),
            final: .init(chunks: ["done"])
        )
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client)

        let events = try await collect(agent, message: "ask me")
        let result = toolFinished(events).first?.2 ?? ""
        #expect(result.contains("not available in this execution context"),
                "no presenter on either rung must report the historic error")
    }

    @Test("two concurrent execute_code hosts do not cross-talk")
    func concurrentExecuteCodeHostsDoNotCrossTalk() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { _ = httpClient.shutdown() }

        let captureA = CaptureBox()
        let captureB = CaptureBox()

        let codeA = "from arc_tools import read_file\nprint(read_file('/tmp/a.txt'))"
        let codeB = "from arc_tools import read_file\nprint(read_file('/tmp/b.txt'))"

        let hostA: (@Sendable (String, [String: Any]) async throws -> String) = { name, args in
            await captureA.set("\(name)|\(args["path"] ?? "")")
            return "CONTENT-A"
        }
        let hostB: (@Sendable (String, [String: Any]) async throws -> String) = { name, args in
            await captureB.set("\(name)|\(args["path"] ?? "")")
            return "CONTENT-B"
        }

        // Run both turns concurrently. Each execute_code call must route to
        // its own agent's host via the per-turn TaskLocal (bound directly on
        // the tool, not through the process-wide dispatcher).
        async let resultA = try await ExecuteCodeTool.$host.withValue(hostA) {
            try await ExecuteCodeTool.entry.handler(["code": codeA])
        }
        async let resultB = try await ExecuteCodeTool.$host.withValue(hostB) {
            try await ExecuteCodeTool.entry.handler(["code": codeB])
        }
        let (resA, resB) = try await (resultA, resultB)

        let gotA = await captureA.get()
        let gotB = await captureB.get()
        #expect(gotA == "read_file|/tmp/a.txt", "agent A's host must be used by its execute_code")
        #expect(gotB == "read_file|/tmp/b.txt", "agent B's host must be used by its execute_code")
        #expect(resA.contains("CONTENT-A"), "agent A must see its own result")
        #expect(resB.contains("CONTENT-B"), "agent B must see its own result")
    }
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

/// Holds the agent under test so a scripted client can steer or interrupt it
/// from inside a `stream(...)` call — the agent does not exist yet when the
/// client is built.
actor TurnAgentBox {
    private var agent: ArcAgent?

    func hold(_ agent: ArcAgent) {
        self.agent = agent
    }

    func steer(_ message: String) async {
        await agent?.steer(message)
    }

    func interrupt() async {
        await agent?.interruptTurn()
    }
}
