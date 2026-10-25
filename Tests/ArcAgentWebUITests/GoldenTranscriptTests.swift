import Foundation
import Synchronization
import Testing
@testable import ArcAgentCore
@testable import ArcWebUI

// ===========================================================================
// MARK: - A7 golden transcript (CONVERGE A7, §3.3, §4 T7)
//
// `Fixtures/golden-transcript.json` is the transcript the LEGACY `runTurn` loop
// persisted for one scripted two-round turn (user → assistant with reasoning +
// one `echo` tool call → tool result → final assistant), captured from the
// legacy loop before the transplant. This suite runs the SAME script through the
// transplanted `runTurn` — a per-turn `ArcAgent` streaming `AgentTurnEvent`s —
// and diffs the stored messages against that fixture.
//
// The fixture is the regression net for every session the transplant touches, so
// it is never regenerated from the new path: a failing diff is a defect in the
// transplant, not a fixture to refresh. `createdAt`, `tps` and `turnDuration`
// are wall-clock values, so those three are compared by shape and by the formula
// that defines them; every other stored field is compared exactly.
// ===========================================================================

/// run a turn to its end, but never wait forever: a transplanted path that
/// awaits a decision nobody will make must fail here, not hang the suite.
private func awaitTurn(
    _ turn: Task<Void, Never>,
    timeout: TimeInterval = 30
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await turn.value; return true }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return false
        }
        let finished = await group.next() ?? false
        group.cancelAll()
        if !finished { turn.cancel() }
        return finished
    }
}

private extension AppState {
    /// bind the turn's durable store and its scripted provider — the two vars
    /// the production init fills from the runtime and from the live config.
    func bindTurnHarness(store: any SessionStore, client: any LLMClient) {
        self.store = store
        self.turnClientOverride = client
    }
}

private extension AppState {
    /// whether a permission card is waiting for a click — the test's read-only
    /// view of the card state (`PendingApproval` carries a continuation and
    /// cannot cross the actor boundary).
    var hasPendingApprovalCard: Bool { pendingApproval != nil }

    /// answer the waiting card, so a mis-wired turn fails its assertions
    /// instead of hanging the suite.
    func answerPendingApproval(with choice: ApprovalChoice) async {
        await resolveApproval(choice)
    }
}

/// one bit the turn's task sets when it returns, so a card poller can tell
/// "the turn ended without a card" from "the turn has not got there yet".
private final class TurnDone: Sendable {
    private let done = Mutex(false)
    func set() { done.withLock { $0 = true } }
    var value: Bool { done.withLock { $0 } }
}

/// one bit a tool handler sets and the test reads: "did the command run?".
private final class RunFlag: Sendable {
    private let ran = Mutex(false)
    func set() { ran.withLock { $0 = true } }
    var value: Bool { ran.withLock { $0 } }
}

/// the scripted provider the fixture was captured with: round one (no tool
/// result in the wire history yet) streams reasoning + text + one tool call;
/// every later round streams the final answer with a usage report.
private struct GoldenScriptedClient: LLMClient {

    struct Round: Sendable {
        var chunks: [String] = []
        var reasoning: String? = nil
        var toolCalls: [ToolCallDelta] = []
        var usage: Usage? = nil
        var finishReason: String = "stop"
    }

    let first: Round
    let final: Round

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
        let round = messages.contains { $0.role == .tool } ? final : first
        return AsyncThrowingStream { continuation in
            if let reasoning = round.reasoning {
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
            continuation.yield(LLMDelta(content: nil, finishReason: round.finishReason))
            continuation.finish()
        }
    }
}

extension ArcWebUITestRoot {

    /// the acceptance artifact, diffed field by field against the new path.
    @Suite("a7 golden transcript", .serialized)
    struct GoldenTranscriptTests {

        // the preset the fixture was captured with; the scripted client replaces
        // the provider, so only the identity matters.
        private static let preset = ModelConfigPreset(
            name: "a7-golden",
            model: "golden-model-1",
            provider: "custom",
            baseURL: "http://127.0.0.1:9/v1",
            apiKey: "a7-golden-key",
            contextLength: 8_000,
            maxOutputTokens: 512
        )

        private static var fixtureURL: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/golden-transcript.json")
        }

        private static func goldenTranscript() throws -> [Message] {
            let data = try Data(contentsOf: Self.fixtureURL)
            return try JSONDecoder().decode([Message].self, from: data)
        }

        /// one scripted turn through the transplanted `runTurn`, returning the
        /// messages that landed in the session store.
        private func runGoldenTurn() async throws -> [Message] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-a7-golden-\(UUID().uuidString)", isDirectory: true)
            let workspace = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

            let store = FileSessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
            let sessionID = "s-a7-golden"
            var session = Session(id: sessionID, title: "Golden turn")
            session.messages = []
            try await store.create(session)

            var echo = StubTool(name: "echo", toolset: "test")
            echo.handler = { args in
                "echo: \(args["value"] as? String ?? "")"
            }

            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [Self.preset]
            f.settings.activeConfig = Self.preset.name
            f.settings.workspaces = [WorkspaceEntry(name: "main", path: workspace.path)]
            f.settings.activeWorkspace = "main"
            f.settings.disabledToolsets = []
            f.registryTools = [echo]
            f.sessions = [session]
            f.activeSessionID = sessionID
            // no chat view: the turn's pushes are rendered for nobody, exactly as
            // the capture ran it.
            f.activeTabID = "logs"
            let app = AppState(renderFixture: f)
            await app.bindTurnHarness(
                store: store,
                client: GoldenScriptedClient(
                    first: .init(
                        chunks: ["Working", " on it. "],
                        reasoning: "considering the request",
                        toolCalls: [
                            ToolCallDelta(index: 0, id: "call-echo-1", name: "echo", arguments: #"{"value":"alpha"}"#)
                        ],
                        finishReason: "tool_calls"
                    ),
                    final: .init(
                        chunks: ["All ", "done."],
                        usage: Usage(promptTokens: 120, completionTokens: 40, totalTokens: 160)
                    )
                )
            )

            await app.runTurn(
                userText: "hello",
                pusher: { _ in },
                sessionID: sessionID,
                selectAfter: false
            )

            let stored = try #require(try await store.get(id: sessionID))
            return stored.messages
        }

        // MARK: - the diff

        @Test("the fixture is the four-message legacy capture")
        func fixtureIsTheLegacyCapture() throws {
            let golden = try Self.goldenTranscript()
            #expect(golden.count == 4)
            #expect(golden.map(\.role) == [.user, .assistant, .tool, .assistant])
            #expect(golden.map(\.content) == ["hello", "Working on it. ", "echo: alpha", "All done."])
            #expect(golden[1].reasoning == "considering the request")
            #expect(golden[1].toolCalls?.map(\.function.name) == ["echo"])
            #expect(golden[2].name == "echo")
            #expect(golden[2].toolCallID == "call-echo-1")
            #expect(golden[3].usage == Usage(promptTokens: 120, completionTokens: 40, totalTokens: 160))
            #expect(golden[3].terminalReason == nil)
        }

        @Test("the transplanted turn persists the legacy transcript field for field")
        func transplantedTurnMatchesGoldenTranscript() async throws {
            let golden = try Self.goldenTranscript()
            let stored = try await runGoldenTurn()

            let differences = Self.differences(golden: golden, stored: stored)
            #expect(
                differences.isEmpty,
                "the transplanted turn diverged from the legacy fixture:\n\(differences.joined(separator: "\n"))"
            )
        }

        // MARK: - comparator

        /// The net has to catch a silently dropped field, not just print one
        /// word of praise: each mutation below is what a lossy event mapping
        /// would store, and each must be reported.
        @Test("the diff catches a dropped field — the net is not a rubber stamp")
        func diffCatchesDroppedFields() throws {
            let golden = try Self.goldenTranscript()
            let last = golden[3]
            let toolRound = golden[1]
            let tool = golden[2]

            var noUsage = golden
            noUsage[3] = Message(
                role: .assistant,
                content: last.content,
                createdAt: last.createdAt,
                reasoning: last.reasoning,
                usage: nil,
                tps: last.tps,
                terminalReason: last.terminalReason,
                turnDuration: last.turnDuration
            )
            #expect(Self.differences(golden: golden, stored: noUsage).contains { $0.contains("usage") },
                    "a dropped usage report must fail the diff")

            var noReasoning = golden
            noReasoning[1] = Message(
                role: .assistant,
                content: toolRound.content,
                toolCalls: toolRound.toolCalls,
                createdAt: toolRound.createdAt,
                reasoning: nil
            )
            #expect(Self.differences(golden: golden, stored: noReasoning).contains { $0.contains("reasoning") },
                    "dropped reasoning must fail the diff")

            var inventedReason = golden
            inventedReason[3] = Message(
                role: .assistant,
                content: last.content,
                createdAt: last.createdAt,
                reasoning: last.reasoning,
                usage: last.usage,
                tps: last.tps,
                terminalReason: "max_iterations",
                turnDuration: last.turnDuration
            )
            #expect(Self.differences(golden: golden, stored: inventedReason).contains { $0.contains("terminalReason") },
                    "a changed terminalReason must fail the diff")

            var noToolCallID = golden
            noToolCallID[2] = Message(
                role: .tool,
                content: tool.content,
                name: tool.name,
                createdAt: tool.createdAt
            )
            #expect(Self.differences(golden: golden, stored: noToolCallID).contains { $0.contains("toolCallID") },
                    "a dropped tool-call id must fail the diff")

            #expect(Self.differences(golden: golden, stored: Array(golden.dropLast())).contains { $0.contains("count") },
                    "a missing message must fail the diff")
        }

        /// Every stored field the card names, compared field by field: content,
        /// reasoning, usage, tps, terminalReason, turnDuration and the tool
        /// name/id/content (plus role, displayText and the tool-call list, which
        /// the store also carries). Wall-clock fields are checked for presence
        /// and for the formula that produces them, not for equality.
        static func differences(golden: [Message], stored: [Message]) -> [String] {
            guard golden.count == stored.count else {
                return ["message count: fixture \(golden.count), stored \(stored.count)"]
            }
            var out: [String] = []
            for (index, pair) in zip(golden, stored).enumerated() {
                let (expected, actual) = pair
                let label = "message[\(index)]"
                if expected.role != actual.role {
                    out.append("\(label).role: fixture \(expected.role.rawValue), stored \(actual.role.rawValue)")
                }
                if expected.content != actual.content {
                    out.append("\(label).content: fixture \(describe(expected.content)), stored \(describe(actual.content))")
                }
                if expected.reasoning != actual.reasoning {
                    out.append("\(label).reasoning: fixture \(describe(expected.reasoning)), stored \(describe(actual.reasoning))")
                }
                if expected.name != actual.name {
                    out.append("\(label).name: fixture \(describe(expected.name)), stored \(describe(actual.name))")
                }
                if expected.toolCallID != actual.toolCallID {
                    out.append("\(label).toolCallID: fixture \(describe(expected.toolCallID)), stored \(describe(actual.toolCallID))")
                }
                if expected.toolCalls != actual.toolCalls {
                    out.append("\(label).toolCalls: fixture \(describe(expected.toolCalls)), stored \(describe(actual.toolCalls))")
                }
                if expected.usage != actual.usage {
                    out.append("\(label).usage: fixture \(describe(expected.usage)), stored \(describe(actual.usage))")
                }
                if expected.terminalReason != actual.terminalReason {
                    out.append("\(label).terminalReason: fixture \(describe(expected.terminalReason)), stored \(describe(actual.terminalReason))")
                }
                if expected.displayText != actual.displayText {
                    out.append("\(label).displayText: fixture \(describe(expected.displayText)), stored \(describe(actual.displayText))")
                }
                if expected.apiContent != actual.apiContent {
                    out.append("\(label).apiContent: fixture \(describe(expected.apiContent)), stored \(describe(actual.apiContent))")
                }

                // createdAt: the fixture's messages carry one; the transplant
                // must stamp one too.
                if (expected.createdAt == nil) != (actual.createdAt == nil) {
                    out.append("\(label).createdAt presence: fixture \(expected.createdAt != nil), stored \(actual.createdAt != nil)")
                }

                // tps: present exactly when the legacy round reported usage, and
                // still output tokens over the round clock (clamped at 0.2 s).
                if (expected.tps == nil) != (actual.tps == nil) {
                    out.append("\(label).tps presence: fixture \(expected.tps != nil), stored \(actual.tps != nil)")
                } else if let tps = actual.tps {
                    let tokens = Double(expected.usage?.completionTokens ?? 0)
                    let ceiling = max(tokens / 0.2, expected.tps ?? 0)
                    if tps <= 0 || tps > ceiling {
                        out.append("\(label).tps: stored \(tps) outside (0, \(ceiling)]")
                    }
                }

                // turnDuration: present exactly on the turn-ending reply and
                // non-negative.
                if (expected.turnDuration == nil) != (actual.turnDuration == nil) {
                    out.append("\(label).turnDuration presence: fixture \(expected.turnDuration != nil), stored \(actual.turnDuration != nil)")
                } else if let duration = actual.turnDuration, duration < 0 || duration > 120 {
                    out.append("\(label).turnDuration: stored \(duration) outside [0, 120]")
                }
            }

            let stamps = stored.compactMap(\.createdAt)
            if stamps.count == stored.count,
               zip(stamps, stamps.dropFirst()).contains(where: { $0 > $1 }) {
                out.append("createdAt is not in transcript order")
            }
            return out
        }

        private static func describe<T>(_ value: T?) -> String {
            guard let value else { return "nil" }
            return "\(value)"
        }
    }
}

// ===========================================================================
// MARK: - A7 transplant guards
//
// The parts of the card that are properties of the tree rather than of one
// transcript: the deleted limit handler, the single ledger writer, the reason
// that reaches the status card, the stop button reaching the turn's agent, and
// the MoA switch the core now reads.
// ===========================================================================

/// counts the provider calls a scripted turn made. A `Mutex` inside a final
/// class: the stream's body is the only writer, and the test reads it after the
/// turn has finished.
private final class StreamCallCounter: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// a `Sendable` handle to the app a tool handler stops — the fixture needs the
/// tool to build the app, and the handler needs the app to stop the turn.
private final class AppRef: Sendable {
    private let stored = Mutex<AppState?>(nil)
    func set(_ app: AppState) { stored.withLock { $0 = app } }
    var app: AppState? { stored.withLock { $0 } }
}

/// a provider that asks for the same tool call every round, so only an
/// interrupt can end the turn before the iteration budget does.
private struct RepeatingToolClient: LLMClient {
    let counter: StreamCallCounter
    let toolCall: ToolCallDelta

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
        counter.bump()
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMDelta(content: nil, toolCalls: [toolCall]))
            continuation.yield(LLMDelta(content: nil, finishReason: "tool_calls"))
            continuation.finish()
        }
    }
}

extension ArcWebUITestRoot {

    @Suite("a7 transplant guards", .serialized)
    struct TransplantGuardTests {

        private static let preset = ModelConfigPreset(
            name: "a7-guard",
            model: "guard-model-1",
            provider: "custom",
            baseURL: "http://127.0.0.1:9/v1",
            apiKey: "a7-guard-key",
            contextLength: 8_000,
            maxOutputTokens: 512
        )

        /// a web UI source file, read from the repo this test lives in.
        private static func webUISource(_ file: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ArcAgentWebUITests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("Sources/ArcWebUI")
            return try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        }

        @Test("the iteration-limit handler is gone; the reason comes from the event stream")
        func iterationLimitHandlerIsDeleted() throws {
            let source = try Self.webUISource("Actions.swift")
            #expect(!source.contains("handleIterationLimit"), "the legacy limit handler must be deleted")
            #expect(source.contains("terminalReason: mapped.terminalReason"),
                    "the stored reply's terminalReason must come from the mapper (completed.terminalReason)")
        }

        @Test("the UI writes no usage ledger row: the core records one per round")
        func theUIWritesNoLedgerRow() throws {
            let source = try Self.webUISource("Actions.swift")
            #expect(!source.contains("UsageLedger"), "the UI must not own a ledger writer")
            #expect(!source.contains("recordUsage"), "the UI must not record usage; the core does, per round")
        }

        @Test("completed.terminalReason reaches the stored reply")
        func terminalReasonReachesTheStoredReply() throws {
            var transcript = TurnTranscript()
            transcript.apply(.textDelta("The conversation reached the maximum iteration limit."))
            transcript.apply(.completed(
                finalText: "The conversation reached the maximum iteration limit.",
                terminalReason: "max_iterations"
            ))

            let stored = AppState.storedAssistantMessage(
                transcript: transcript,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tps: nil,
                turnDuration: 1.5
            )
            #expect(stored.role == .assistant)
            #expect(stored.terminalReason == "max_iterations")
            #expect(stored.content == "The conversation reached the maximum iteration limit.")
            #expect(stored.usage == nil)
            #expect(stored.turnDuration == 1.5)
        }

        @Test("the stop button interrupts the turn's own agent")
        func stopButtonInterruptsTheTurnAgent() async throws {
            let workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-a7-stop-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

            let store = FileSessionStore(directory: workspace.appendingPathComponent("sessions", isDirectory: true))
            let sessionID = "s-a7-stop"
            try await store.create(Session(id: sessionID, title: "Stop turn"))

            let counter = StreamCallCounter()
            let appRef = AppRef()
            var probe = StubTool(name: "probe", toolset: "test")
            // the tool asks for the stop while the turn is in flight — the one
            // reachable moment for the stop button.
            probe.handler = { _ in
                if let app = appRef.app {
                    await app.requestStopTurn(sessionID: sessionID)
                }
                return "probed"
            }

            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [Self.preset]
            f.settings.activeConfig = Self.preset.name
            f.settings.workspaces = [WorkspaceEntry(name: "main", path: workspace.path)]
            f.settings.activeWorkspace = "main"
            f.settings.disabledToolsets = []
            f.registryTools = [probe]
            f.sessions = [Session(id: sessionID, title: "Stop turn")]
            f.activeSessionID = sessionID
            f.activeTabID = "logs"
            let app = AppState(renderFixture: f)
            appRef.set(app)
            await app.bindTurnHarness(
                store: store,
                client: RepeatingToolClient(
                    counter: counter,
                    toolCall: ToolCallDelta(index: 0, id: "call-probe", name: "probe", arguments: "{}")
                )
            )

            await app.runTurn(
                userText: "go",
                pusher: { _ in },
                sessionID: sessionID,
                selectAfter: false
            )

            #expect(counter.value == 1, "an interrupted turn must not ask the provider for another round")

            let stored = try #require(try await store.get(id: sessionID))
            let reply = try #require(stored.messages.last)
            #expect(reply.role == .assistant)
            #expect(reply.terminalReason == "user_stopped",
                    "the stop must reach the turn's agent, not just the UI flag")
            #expect(reply.content == "Turn interrupted — stopped by the user.")
            #expect(stored.messages.contains { $0.role == .tool && $0.name == "probe" })
        }

        /// a state whose session runs one scripted `terminal` call for `command`
        /// through the real approval gate, so the turn's `headless` flag is the only
        /// difference between the two transports.
        private func turnHarness(
            sessionID: String,
            command: String
        ) async throws -> (app: AppState, ran: RunFlag, store: FileSessionStore) {
            let workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-a7-approval-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let store = FileSessionStore(directory: workspace.appendingPathComponent("sessions", isDirectory: true))
            try await store.create(Session(id: sessionID, title: "Approval turn"))

            let ran = RunFlag()
            var terminal = StubTool(name: "terminal", toolset: "core")
            terminal.handler = { _ in
                ran.set()
                return "ran"
            }

            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [Self.preset]
            f.settings.activeConfig = Self.preset.name
            f.settings.workspaces = [WorkspaceEntry(name: "main", path: workspace.path)]
            f.settings.activeWorkspace = "main"
            f.settings.disabledToolsets = []
            f.registryTools = [terminal]
            f.sessions = [Session(id: sessionID, title: "Approval turn")]
            f.activeSessionID = sessionID
            f.activeTabID = "logs"
            let app = AppState(renderFixture: f)
            await app.bindTurnHarness(
                store: store,
                client: GoldenScriptedClient(
                    first: .init(
                        toolCalls: [
                            ToolCallDelta(
                                index: 0,
                                id: "call-terminal-1",
                                name: "terminal",
                                arguments: "{\"command\":\"\(command)\"}"
                            )
                        ],
                        finishReason: "tool_calls"
                    ),
                    final: .init(chunks: ["done"])
                )
            )
            return (app, ran, store)
        }

        /// answer the waiting card as soon as one appears, or give up when the
        /// turn has returned without posting one. Returns whether a card was
        /// actually waiting — the whole point of the two tests below.
        private func answerCardIfAny(
            _ app: AppState,
            sessionID: String,
            with choice: ApprovalChoice,
            turnDone: TurnDone,
            timeout: TimeInterval = 10
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await app.hasPendingApprovalCard {
                    await app.answerPendingApproval(with: choice)
                    return true
                }
                if turnDone.value { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }

        @Test("a queue (headless) turn never waits on an approval card")
        func headlessTurnNeverWaitsOnACard() async throws {
            let sessionID = "s-a7-headless"
            let (app, ran, store) = try await turnHarness(sessionID: sessionID, command: "rm -rf /")

            let done = TurnDone()
            let turn = Task {
                await app.runTurn(
                    userText: "go",
                    pusher: { _ in },
                    sessionID: sessionID,
                    headless: true,
                    selectAfter: false
                )
                done.set()
            }
            let sawCard = await answerCardIfAny(app, sessionID: sessionID, with: .deny, turnDone: done)
            let finished = await awaitTurn(turn)
            #expect(finished, "the headless turn never finished")

            #expect(!sawCard, "a scheduled job has nobody to answer a card")
            #expect(!ran.value, "a critical command must never run in a headless turn")
            let stored = try #require(try await store.get(id: sessionID))
            let toolResult = stored.messages.last { $0.role == .tool }?.content ?? ""
            #expect(toolResult.contains("blocked by security policy"),
                    "the core's refusal must be what the transcript shows: \(toolResult)")
            #expect(stored.messages.last?.role == .assistant)
            #expect(stored.messages.last?.content == "done")
        }

        @Test("an interactive turn reaches the approval card instead of approving silently")
        func interactiveTurnReachesTheCard() async throws {
            let sessionID = "s-a7-interactive"
            let (app, ran, store) = try await turnHarness(sessionID: sessionID, command: "rm -rf /tmp/a7-approval")

            let done = TurnDone()
            let turn = Task {
                await app.runTurn(
                    userText: "go",
                    pusher: { _ in },
                    sessionID: sessionID,
                    headless: false,
                    selectAfter: false
                )
                done.set()
            }
            let sawCard = await answerCardIfAny(app, sessionID: sessionID, with: .once, turnDone: done)
            let finished = await awaitTurn(turn)
            #expect(finished, "the interactive turn never finished after the card was answered")

            #expect(sawCard, "an interactive turn must pause on the permission card")
            #expect(ran.value, "the click is what lets the command run")
            let stored = try #require(try await store.get(id: sessionID))
            #expect(stored.messages.last?.role == .assistant)
            #expect(stored.messages.last?.content == "done")
        }

        @Test("the MoA switch is what decides whether the core runs the advisory")
        func moaSwitchMapsToTheCoreConfiguration() {
            var config = MoAConfig()
            #expect(AppState.turnMoAConfig(config, enabledBySwitch: true).enabled == false,
                    "no reference models means nothing to fan out")

            config.referenceModels = [MoAConfig.Role(model: "reference-1")]
            #expect(AppState.turnMoAConfig(config, enabledBySwitch: true).enabled)
            #expect(AppState.turnMoAConfig(config, enabledBySwitch: false).enabled == false,
                    "the UI switch stays authoritative, as it was in the legacy loop")
        }
    }
}