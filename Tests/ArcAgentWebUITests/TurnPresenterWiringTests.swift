import Foundation
import Testing
@testable import ArcAgentCore
@testable import ArcWebUI
import WebUICore

// ===========================================================================
// MARK: - turn presenter wiring (CONVERGE A6, §3.1, §4 T6)
//
// the headless policy itself is pinned in `HeadlessApprovalPolicyTests` (the
// pure function, no agent, no socket). this file pins the wiring: the closures
// a minted turn agent is handed are driven directly (card state, card markup,
// decisions), and scripted turns prove the agent itself reaches the permission
// card for a dangerous command before it runs anything — the card's stop rule.
// ===========================================================================

// `ApprovalDecision` is not `Equatable` in the core (this card does not widen
// that surface), so decisions are matched, not compared.
private func isApprove(_ decision: ApprovalDecision) -> Bool {
    if case .approve = decision { return true }
    return false
}

private func isDeny(_ decision: ApprovalDecision) -> Bool {
    if case .deny = decision { return true }
    return false
}

/// a `Sendable` projection of `PendingApproval`: the real struct carries the
/// answer continuation, so it cannot cross the actor boundary into a test.
private struct PendingApprovalPeek: Sendable, Equatable {
    let command: String
    let description: String
    let sessionID: String
}

/// the same projection for `PendingClarify`.
private struct PendingClarifyPeek: Sendable, Equatable {
    let question: String
    let choices: [String]
    let sessionID: String
}

private extension AppState {
    var approvalPeek: PendingApprovalPeek? {
        pendingApproval.map {
            PendingApprovalPeek(command: $0.command, description: $0.description, sessionID: $0.sessionID)
        }
    }

    var clarifyPeek: PendingClarifyPeek? {
        pendingClarify.map {
            PendingClarifyPeek(question: $0.question, choices: $0.choices, sessionID: $0.sessionID)
        }
    }
}

/// collects what a turn raised while it was in flight — the interaction closure
/// is `@Sendable`, so it cannot mutate a captured `var`.
private actor CardBox {
    private(set) var approval: PendingApprovalPeek?
    private(set) var clarify: PendingClarifyPeek?

    func setApproval(_ peek: PendingApprovalPeek?) { approval = peek }
    func setClarify(_ peek: PendingClarifyPeek?) { clarify = peek }
}

/// a registry tool that records the calls it receives. The core's approval gate
/// keys on the tool NAME, so the stub is named `terminal` and never touches a
/// shell — "did the command run?" is a count, not a filesystem effect.
private struct RecordingTool: AgentTool {
    let name: String
    let toolset: String
    let handler: ToolHandler

    var description: String { "A recording stub tool." }
    var schema: JSONSchema { .object(properties: [:]) }
    var checkFn: ToolRequirementCheck? { nil }
}

/// a scripted streaming provider: round one (no tool result yet) emits the tool
/// call, every later round emits the final text — the OpenAI-compatible wire
/// order the turn loop reads.
private struct ScriptedTurnClient: LLMClient {

    struct Round: Sendable {
        var chunks: [String] = []
        var toolCalls: [ToolCallDelta] = []
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
            for chunk in round.chunks {
                continuation.yield(LLMDelta(content: chunk))
            }
            if !round.toolCalls.isEmpty {
                continuation.yield(LLMDelta(content: nil, toolCalls: round.toolCalls))
            }
            continuation.yield(LLMDelta(
                content: nil,
                finishReason: round.toolCalls.isEmpty ? "stop" : "tool_calls"
            ))
            continuation.finish()
        }
    }
}

extension ArcWebUITestRoot {

    /// the command text an approval card shows: `ApprovalRequest.command` is
    /// the tool call's raw arguments JSON, so the card unwraps a terminal call
    /// and shows anything else verbatim.
    @Suite("approval card command text", .serialized)
    struct ApprovalCardCommandTests {

        @Test("a terminal call's card shows the command, not the raw json")
        func unwrapsTerminalArguments() {
            let wrapped = ApprovalRequest(
                command: #"{"command":"rm -rf /tmp/a6"}"#,
                description: "Execute shell command",
                sessionKey: "s-a6"
            )
            #expect(AppState.approvalCommand(for: wrapped) == "rm -rf /tmp/a6")
            let plain = ApprovalRequest(command: "rm -rf /tmp/a6", description: "", sessionKey: "s-a6")
            #expect(AppState.approvalCommand(for: plain) == "rm -rf /tmp/a6")
            #expect(AppState.approvalCommand(for: wrapped) != wrapped.command,
                    "the card must not show the arguments wrapper")
        }

        @Test("an unrecognised request is shown verbatim, never hidden")
        func keepsUnrecognisedText() {
            let code = ApprovalRequest(command: #"{"code":"print(1)"}"#, description: "", sessionKey: "s-a6")
            #expect(AppState.approvalCommand(for: code) == #"{"code":"print(1)"}"#)
            let junk = ApprovalRequest(command: "not json at all", description: "", sessionKey: "s-a6")
            #expect(AppState.approvalCommand(for: junk) == "not json at all")
        }
    }

    /// the wiring, pinned through the values a minted agent is handed plus
    /// scripted turns that run the agent's own gate. `.serialized` for the same
    /// reason the target root is: `AppState` pokes process-global tool boxes.
    @Suite("turn presenter wiring", .serialized)
    struct TurnPresenterWiringTests {

        // no network: the scripted client replaces the provider client before
        // the turn runs.
        private static let preset = ModelConfigPreset(
            name: "a6-stub",
            model: "stub-model-1",
            provider: "custom",
            baseURL: "http://127.0.0.1:9/v1",
            apiKey: "a6-stub-key",
            contextLength: 8_000,
            maxOutputTokens: 512
        )

        // MARK: harness pieces

        /// counts stub tool executions, so "did the command run?" is a count.
        private actor StubRuns {
            private(set) var commands: [String] = []
            var count: Int { commands.count }
            func record(_ command: String) { commands.append(command) }
        }

        private struct Harness {
            let app: AppState
            let runs: StubRuns
            let pushes: PushRecorder
            let sessionID: String
            let workspace: URL
        }

        /// a fixture state whose gate is armed, whose session has a live turn,
        /// and whose registry carries a recording `terminal` stub.
        private func makeHarness(
            sessionID: String,
            liveTurn: Bool = true,
            approvalMode: ApprovalMode = .manual
        ) -> Harness {
            let workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-a6-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

            let runs = StubRuns()
            let terminal = RecordingTool(name: "terminal", toolset: "core") { args in
                let command = args["command"] as? String ?? ""
                await runs.record(command)
                return "ran: \(command)"
            }
            let probe = RecordingTool(name: "a6-probe", toolset: "test") { _ in
                await runs.record("a6-probe")
                return "probe ran"
            }

            var f = AppState.RenderFixture()
            f.settings.workspaces = [WorkspaceEntry(name: "main", path: workspace.path)]
            f.settings.activeWorkspace = "main"
            f.settings.disabledToolsets = []
            f.registryTools = [terminal, probe, ClarifyTool.entry]
            f.approvalManager = ApprovalManager(mode: approvalMode)
            if liveTurn {
                f.activeTurns = [sessionID: LiveTurn(sessionID: sessionID, userText: "go", attachments: [])]
            }
            f.activeSessionID = sessionID
            return Harness(
                app: AppState(renderFixture: f),
                runs: runs,
                pushes: PushRecorder(),
                sessionID: sessionID,
                workspace: workspace
            )
        }

        private func toolCall(_ name: String, _ arguments: [String: Any]) -> ToolCall {
            let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
            return ToolCall(
                id: "call-\(name)",
                type: "function",
                function: .init(name: name, arguments: String(data: data, encoding: .utf8) ?? "{}")
            )
        }

        private func terminalCall(_ command: String) -> ToolCall {
            toolCall("terminal", ["command": command])
        }

        private func scriptedTurn(_ toolName: String, _ arguments: [String: Any]) -> ScriptedTurnClient {
            let encoded = String(
                data: (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8),
                encoding: .utf8
            ) ?? "{}"
            return ScriptedTurnClient(
                first: .init(toolCalls: [
                    ToolCallDelta(index: 0, id: "call-\(toolName)", name: toolName, arguments: encoded)
                ]),
                final: .init(chunks: ["done"])
            )
        }

        private func toolResults(_ events: [AgentTurnEvent]) -> [String] {
            events.compactMap { event in
                if case .toolCallFinished(_, _, let result) = event { return result }
                return nil
            }
        }

        /// the markup pushed so far, all batches joined — the cards the owner
        /// actually rendered.
        private func pushed(_ h: Harness) async -> String { await h.pushes.html }
        private func lastPushed(_ h: Harness) async -> String { await h.pushes.lastHTML }

        /// poll until the app has a pending approval, or the deadline passes.
        /// the turn raises the card from its own task, so there is no callback
        /// to await; `nil` means the card never appeared.
        private func waitForApproval(
            _ app: AppState,
            timeout: TimeInterval = 10
        ) async -> PendingApprovalPeek? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let peek = await app.approvalPeek { return peek }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }

        private func waitForClarify(
            _ app: AppState,
            timeout: TimeInterval = 10
        ) async -> PendingClarifyPeek? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let peek = await app.clarifyPeek { return peek }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }

        /// mint a turn agent through A5's factory + A6's wiring, run one scripted
        /// turn to completion, and release the agent's http client on every path.
        private func runScriptedTurn(
            _ harness: Harness,
            headless: Bool,
            client: ScriptedTurnClient,
            interact: @Sendable () async -> Void = {}
        ) async throws -> [AgentTurnEvent] {
            let minted = await harness.app.makeTurnAgent(
                preset: Self.preset,
                profileContext: nil,
                thinking: "off",
                headless: headless,
                sessionID: harness.sessionID,
                pusher: harness.pushes.push
            )
            let agent = minted.agent
            do {
                // prime owns the http client the loop needs; the scripted client
                // replaces the provider client it builds, exactly as the core's
                // turn-event tests substitute theirs.
                try await agent.prime()
                await agent.setClient(client)
                let turn = Task { () throws -> [AgentTurnEvent] in
                    var events: [AgentTurnEvent] = []
                    for try await event in agent.streamTurn(message: "go") {
                        events.append(event)
                    }
                    return events
                }
                await interact()
                let events = try await turn.value
                await agent.shutdownHTTPClient()
                return events
            } catch {
                await agent.shutdownHTTPClient()
                throw error
            }
        }

        // MARK: - the legacy path the scheduler still uses

        @Test("a headless runTool blocks a critical command and never executes it")
        func headlessRunToolBlocksCritical() async {
            let h = makeHarness(sessionID: "s-a6-cron-critical")
            let result = await h.app.runTool(
                terminalCall("mkfs.ext4 /dev/disk9"),
                sessionID: h.sessionID,
                pusher: { _ in },
                headless: true
            )
            #expect(result == HeadlessApprovalPolicy.blockedCommandMessage)
            #expect(await h.runs.count == 0, "a blocked command must not reach the tool")
            #expect(await h.app.approvalPeek == nil, "a headless run never posts a card")
        }

        @Test("a headless runTool proceeds with a dangerous command nobody must approve")
        func headlessRunToolProceedsForNonCritical() async {
            let h = makeHarness(sessionID: "s-a6-cron-proceed")
            let result = await h.app.runTool(
                terminalCall("rm -rf /tmp/a6-not-real"),
                sessionID: h.sessionID,
                pusher: { _ in },
                headless: true
            )
            #expect(result == "ran: rm -rf /tmp/a6-not-real")
            #expect(await h.runs.count == 1, "the scheduler policy is approve-and-proceed")
            #expect(await h.app.approvalPeek == nil)
        }

        @Test("the interactive runTool path still pauses on the permission card")
        func interactiveRunToolStillReachesTheCard() async {
            let h = makeHarness(sessionID: "s-a6-legacy-card")
            let outcome = Task {
                await h.app.runTool(
                    terminalCall("rm -rf /tmp/a6-legacy"),
                    sessionID: h.sessionID,
                    pusher: h.pushes.push,
                    headless: false
                )
            }
            let card = await waitForApproval(h.app)
            #expect(card?.command == "rm -rf /tmp/a6-legacy")
            #expect(card?.sessionID == h.sessionID)
            let html = await pushed(h)
            #expect(html.contains("approval-card"), "the permission card must be pushed")
            #expect(html.contains("rm -rf /tmp/a6-legacy"))
            await h.app.resolveApproval(.deny)
            #expect(await outcome.value == "Error: command rejected by user approval.")
            #expect(await h.runs.count == 0)
        }

        // MARK: - the presenters a minted agent is handed

        @Test("the interactive approval presenter posts the card and carries the click")
        func interactiveApprovalPresenterCarriesTheClick() async {
            let h = makeHarness(sessionID: "s-a6-presenter-approve")
            let presenters = await h.app.turnPresenters(
                sessionID: h.sessionID,
                headless: false,
                pusher: h.pushes.push
            )
            #expect(presenters.clarify != nil, "an interactive turn binds clarify")
            let answer = Task {
                await presenters.approval(ApprovalRequest(
                    command: #"{"command":"rm -rf /tmp/a6-presenter"}"#,
                    description: "Execute shell command",
                    sessionKey: h.sessionID
                ))
            }
            let card = await waitForApproval(h.app)
            #expect(card?.command == "rm -rf /tmp/a6-presenter",
                    "the card shows the command, not the raw arguments json")
            #expect(card?.sessionID == h.sessionID)
            let html = await pushed(h)
            #expect(html.contains("approval-card"))
            #expect(html.contains("approval-deny"), "the card's buttons are unchanged")
            await h.app.resolveApproval(.once)
            #expect(isApprove(await answer.value))
            #expect(await h.app.approvalPeek == nil, "the card clears once answered")
            let after = await lastPushed(h)
            #expect(!after.contains("approval-card"))
        }

        @Test("a denied click becomes a denial, not a default approval")
        func interactiveApprovalPresenterCarriesADenial() async {
            let h = makeHarness(sessionID: "s-a6-presenter-deny")
            let presenters = await h.app.turnPresenters(
                sessionID: h.sessionID,
                headless: false,
                pusher: h.pushes.push
            )
            let answer = Task {
                await presenters.approval(ApprovalRequest(
                    command: "rm -rf /tmp/a6-presenter",
                    description: "Run `rm -rf /tmp/a6-presenter`",
                    sessionKey: h.sessionID
                ))
            }
            let card = await waitForApproval(h.app)
            #expect(card != nil, "the dangerous command must reach the card")
            await h.app.resolveApproval(.deny)
            #expect(isDeny(await answer.value))
        }

        @Test("with no live turn the interactive presenter denies instead of approving blind")
        func interactiveApprovalPresenterDeniesWithoutALiveTurn() async {
            let h = makeHarness(sessionID: "s-a6-no-turn", liveTurn: false)
            let presenters = await h.app.turnPresenters(
                sessionID: h.sessionID,
                headless: false,
                pusher: h.pushes.push
            )
            let decision = await presenters.approval(ApprovalRequest(
                command: "rm -rf /tmp/a6-no-turn",
                description: "Run `rm -rf /tmp/a6-no-turn`",
                sessionKey: h.sessionID
            ))
            #expect(isDeny(decision), "nothing can answer the card, so the command must not run")
            #expect(await h.app.approvalPeek == nil)
            let html = await pushed(h)
            #expect(!html.contains("approval-card"))
        }

        @Test("the headless approval presenter decides by policy and never posts a card")
        func headlessApprovalPresenterNeverPostsACard() async {
            let h = makeHarness(sessionID: "s-a6-headless-presenter")
            let presenters = await h.app.turnPresenters(
                sessionID: h.sessionID,
                headless: true,
                pusher: h.pushes.push
            )
            #expect(presenters.clarify == nil, "headless has nobody to clarify with")

            let dangerous = await presenters.approval(ApprovalRequest(
                command: "rm -rf /tmp/a6-headless",
                description: "Scheduled: `rm -rf /tmp/a6-headless`",
                sessionKey: h.sessionID
            ))
            #expect(isApprove(dangerous), "the scheduler policy proceeds below critical")

            let critical = await presenters.approval(ApprovalRequest(
                command: "dd if=/dev/zero of=/dev/disk9",
                description: "Scheduled: `dd …`",
                sessionKey: h.sessionID
            ))
            #expect(isDeny(critical), "the scheduler policy refuses critical")

            #expect(await h.app.approvalPeek == nil, "a scheduled job must never wait on a card")
            let html = await pushed(h)
            #expect(!html.contains("approval-card"))
        }

        @Test("the headless approval presenter never approves a destructive command")
        func headlessApprovalPresenterRefusesDestructiveCommands() async {
            let h = makeHarness(sessionID: "s-a6-headless-destructive")
            let presenters = await h.app.turnPresenters(
                sessionID: h.sessionID,
                headless: true,
                pusher: h.pushes.push
            )
            // the core hands the presenter the call's raw arguments json; the
            // detector's anchored critical pattern only matches the bare
            // command, so the presenter must unwrap before classifying.
            let wrapped = await presenters.approval(ApprovalRequest(
                command: #"{"command":"rm -rf /"}"#,
                description: "Execute shell command",
                sessionKey: h.sessionID
            ))
            #expect(isDeny(wrapped), "rm -rf / must never be approved by a headless presenter")
            let unwrapped = await presenters.approval(ApprovalRequest(
                command: "rm -rf /",
                description: "Execute shell command",
                sessionKey: h.sessionID
            ))
            #expect(isDeny(unwrapped))
            #expect(await h.app.approvalPeek == nil)
        }

        @Test("the clarify presenter renders the clarify card and returns the answer")
        func clarifyPresenterUsesTheClarifyCard() async {
            let h = makeHarness(sessionID: "s-a6-clarify")
            let presenters = await h.app.turnPresenters(
                sessionID: h.sessionID,
                headless: false,
                pusher: h.pushes.push
            )
            let answer = Task {
                await presenters.clarify?("Which colour?", ["red", "blue"])
            }
            let card = await waitForClarify(h.app)
            #expect(card?.question == "Which colour?")
            #expect(card?.choices == ["red", "blue"])
            #expect(card?.sessionID == h.sessionID)
            let html = await pushed(h)
            #expect(html.contains("clarify-card"), "the clarify card must be pushed")
            #expect(html.contains("clarify-choice-0"), "the card's ids are unchanged")
            #expect(html.contains("clarify-form"))
            await h.app.respondClarify("blue")
            #expect(await answer.value == "blue")
        }

        @Test("the clarify presenter reports no live turn as no answer, not a fake one")
        func clarifyPresenterWithoutALiveTurnReturnsNil() async {
            let h = makeHarness(sessionID: "s-a6-clarify-none", liveTurn: false)
            let presenters = await h.app.turnPresenters(
                sessionID: h.sessionID,
                headless: false,
                pusher: h.pushes.push
            )
            #expect(await presenters.clarify?("Which colour?", []) == nil)
            #expect(await h.app.clarifyPeek == nil)
        }

        @Test("the code host dispatches through the turn's own registry")
        func codeHostDispatchesThroughTheTurnSession() async throws {
            let h = makeHarness(sessionID: "s-a6-code-host")
            let presenters = await h.app.turnPresenters(
                sessionID: h.sessionID,
                headless: true,
                pusher: { _ in }
            )
            let output = try await presenters.codeHost("a6-probe", ["value": 1])
            #expect(output == "probe ran")
            #expect(await h.runs.count == 1)
        }

        // MARK: - the agent's own gate (the stop rule)

        @Test("an interactive turn's dangerous command reaches the card, and a denial blocks it")
        func interactiveTurnReachesTheCardAndDenialBlocks() async throws {
            let h = makeHarness(sessionID: "s-a6-turn-deny")
            let box = CardBox()
            let events = try await runScriptedTurn(
                h,
                headless: false,
                client: scriptedTurn("terminal", ["command": "rm -rf /tmp/a6-agent"])
            ) {
                await box.setApproval(await waitForApproval(h.app))
                await h.app.resolveApproval(.deny)
            }

            let card = await box.approval
            #expect(card != nil, "the dangerous command must reach the permission card")
            #expect(card?.command.contains("rm -rf /tmp/a6-agent") == true)
            #expect(card?.sessionID == h.sessionID)
            let html = await pushed(h)
            #expect(html.contains("approval-card"))
            let result = toolResults(events).first ?? ""
            #expect(result.contains("blocked by security policy"), "the denial must reach the model: \(result)")
            #expect(await h.runs.count == 0, "a denied command must not execute")
        }

        @Test("an approved dangerous command on a minted turn executes")
        func interactiveTurnApprovalExecutes() async throws {
            let h = makeHarness(sessionID: "s-a6-turn-approve")
            let events = try await runScriptedTurn(
                h,
                headless: false,
                client: scriptedTurn("terminal", ["command": "rm -rf /tmp/a6-agent-ok"])
            ) {
                _ = await waitForApproval(h.app)
                await h.app.resolveApproval(.once)
            }

            #expect(toolResults(events).first == "ran: rm -rf /tmp/a6-agent-ok")
            #expect(await h.runs.count == 1, "the click is the approval that lets it run")
        }

        @Test("a headless turn follows the scheduler policy and posts no card")
        func headlessTurnFollowsTheSchedulerPolicy() async throws {
            let h = makeHarness(sessionID: "s-a6-turn-headless")
            let events = try await runScriptedTurn(
                h,
                headless: true,
                client: scriptedTurn("terminal", ["command": "rm -rf /tmp/a6-headless-agent"])
            )
            #expect(toolResults(events).first == "ran: rm -rf /tmp/a6-headless-agent")
            #expect(await h.runs.count == 1)
            let html = await pushed(h)
            #expect(!html.contains("approval-card"), "a scheduled job has nobody to ask")
            #expect(await h.app.approvalPeek == nil)
        }

        @Test("a headless turn blocks a destructive command even wrapped in call arguments")
        func headlessTurnBlocksCritical() async throws {
            let h = makeHarness(sessionID: "s-a6-turn-headless-critical")
            let events = try await runScriptedTurn(
                h,
                headless: true,
                client: scriptedTurn("terminal", ["command": "rm -rf /"])
            )
            let result = toolResults(events).first ?? ""
            #expect(result.contains("blocked by security policy"), "critical must be refused: \(result)")
            #expect(await h.runs.count == 0)
            #expect(await h.app.approvalPeek == nil)
            let html = await pushed(h)
            #expect(!html.contains("approval-card"))
        }

        @Test("a minted turn's clarify call is answered by the clarify card")
        func mintedTurnClarifyIsAnsweredByTheCard() async throws {
            let h = makeHarness(sessionID: "s-a6-turn-clarify")
            let box = CardBox()
            let events = try await runScriptedTurn(
                h,
                headless: false,
                client: scriptedTurn("clarify", ["question": "Which colour?", "choices": ["red", "blue"]])
            ) {
                await box.setClarify(await waitForClarify(h.app))
                await h.app.respondClarify("blue")
            }

            #expect(await box.clarify?.question == "Which colour?")
            #expect(await box.clarify?.choices == ["red", "blue"])
            let html = await pushed(h)
            #expect(html.contains("clarify-card"))
            #expect(toolResults(events).first == "blue", "the answer becomes the tool result")
        }

        @Test("a headless turn's clarify keeps the tool's historic no-human answer")
        func headlessTurnClarifyReportsNoPresenter() async throws {
            let h = makeHarness(sessionID: "s-a6-turn-clarify-headless")
            let events = try await runScriptedTurn(
                h,
                headless: true,
                client: scriptedTurn("clarify", ["question": "Which colour?"])
            )
            let result = toolResults(events).first ?? ""
            #expect(result.contains("not available in this execution context"), "got: \(result)")
            let html = await pushed(h)
            #expect(!html.contains("clarify-card"))
        }
    }
}