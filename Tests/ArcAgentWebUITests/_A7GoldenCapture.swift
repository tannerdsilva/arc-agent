import Foundation
import Testing
@testable import ArcAgentCore
@testable import ArcWebUI

// ===========================================================================
// MARK: - A7 golden transcript CAPTURE (temporary; deleted after capture)
//
// Runs the LEGACY `runTurn` loop once against a scripted provider and freezes
// the messages it persisted into `Fixtures/golden-transcript.json`. That file
// is the acceptance artifact the transplant is diffed against; this entry point
// exists only to prove where the fixture came from and is removed with the
// legacy loop.
// ===========================================================================

/// the scripted provider: round one (no tool result in the wire history yet)
/// streams reasoning + text + one tool call; every later round streams the
/// final answer with a usage report. Deterministic, no socket.
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

private extension AppState {
    /// bind the turn's durable store and its scripted provider.
    func setTurnHarness(store: any SessionStore, client: any LLMClient) {
        self.store = store
        self.turnClientOverride = client
    }
}

@Suite("a7 golden capture", .serialized)
struct A7GoldenCapture {

    private static let preset = ModelConfigPreset(
        name: "a7-golden",
        model: "golden-model-1",
        provider: "custom",
        baseURL: "http://127.0.0.1:9/v1",
        apiKey: "stub-key",
        contextLength: 8_000,
        maxOutputTokens: 512
    )

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden-transcript.json")
    }

    @Test("capture the legacy loop's persisted transcript")
    func captureLegacyTranscript() async throws {
        guard ProcessInfo.processInfo.environment["ARC_GOLDEN_CAPTURE"] == "1" else {
            return   // capture runs are explicit; a normal suite run never writes the fixture
        }

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
        f.activeTabID = "logs"
        let app = AppState(renderFixture: f)
        await app.setTurnHarness(store: store, client: GoldenScriptedClient(
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
        ))

        await app.runTurn(
            userText: "hello",
            pusher: { _ in },
            sessionID: sessionID,
            selectAfter: false
        )

        let stored = try #require(try await store.get(id: sessionID))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: Self.fixtureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(stored.messages).write(to: Self.fixtureURL, options: .atomic)
        print("[a7] captured \(stored.messages.count) messages → \(Self.fixtureURL.path)")
        for (i, m) in stored.messages.enumerated() {
            print("[a7] \(i) \(m.role.rawValue) content=\(m.content ?? "nil") reason=\(m.reasoning ?? "nil") calls=\(m.toolCalls?.count ?? 0) usage=\(m.usage != nil) tps=\(m.tps != nil) terminal=\(m.terminalReason ?? "nil") duration=\(m.turnDuration != nil)")
        }
    }
}