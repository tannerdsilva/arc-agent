import Foundation
import Synchronization
import Testing
@testable import ArcAgentCore
@testable import ArcWebUI

// ===========================================================================
// MARK: - A8 scheduled-job runner on the one engine
//
// The retired runner was a second turn engine: it built its own system prompt
// from `Actions.buildSystemPrompt`, looped `client.complete` + `runTool` up to
// 25 times, and persisted its own shapes. It now mints the same per-turn
// `ArcAgent` a chat mints (`makeTurnAgent(…headless: true)`) and consumes
// `streamTurn`. These tests pin the four observable behaviours the card says
// must survive: the returned `lastOutput`, the 25-round cap, per-message
// persistence, and the job session's title.
// ===========================================================================

/// the scripted provider the job turns run against: one tool round then a final
/// answer, or a tool call on every round (the cap test).
final class JobScriptClient: LLMClient, Sendable {

    enum Mode: Sendable {
        case toolThenFinal
        case alwaysTool
    }

    private let mode: Mode
    private let requests = Mutex<[[Message]]>([])

    init(mode: Mode) { self.mode = mode }

    /// the messages of every request the job's agent sent, in order.
    var captured: [[Message]] { requests.withLock { $0 } }

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        throw LLMError.apiError(statusCode: 500, message: "scripted client is streaming-only")
    }

    func complete(
        messages: [Message], tools: [[String: Any]]?, reasoningEffort: String?
    ) async throws -> LLMResponse {
        try await complete(messages: messages, tools: tools)
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        stream(messages: messages, tools: tools, reasoningEffort: nil)
    }

    func stream(
        messages: [Message], tools: [[String: Any]]?, reasoningEffort: String?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        let round = requests.withLock { store -> Int in
            store.append(messages)
            return store.count - 1
        }
        let sawToolResult = messages.contains { $0.role == .tool }
        return AsyncThrowingStream { continuation in
            switch mode {
            case .toolThenFinal:
                if sawToolResult {
                    continuation.yield(LLMDelta(content: "Job done."))
                    continuation.yield(LLMDelta(content: nil, finishReason: "stop"))
                } else {
                    continuation.yield(LLMDelta(content: nil, toolCalls: [
                        ToolCallDelta(index: 0, id: "call-echo-1", name: "echo",
                                      arguments: #"{"value":"alpha"}"#)
                    ]))
                    continuation.yield(LLMDelta(content: nil, finishReason: "tool_calls"))
                }
            case .alwaysTool:
                continuation.yield(LLMDelta(content: nil, toolCalls: [
                    ToolCallDelta(index: 0, id: "call-echo-\(round)", name: "echo",
                                  arguments: #"{"value":"alpha"}"#)
                ]))
                continuation.yield(LLMDelta(content: nil, finishReason: "tool_calls"))
            }
            continuation.finish()
        }
    }
}

extension ArcWebUITestRoot {

    @Suite("scheduled job runner", .serialized)
    struct ScheduledJobRunnerTests {

        static let preset = ModelConfigPreset(
            name: "a8-job",
            model: "a8-job-model",
            provider: "custom",
            baseURL: "http://127.0.0.1:9/v1",
            contextLength: 8_000,
            maxOutputTokens: 512
        )

        static let limitText = "The conversation reached the maximum iteration limit. Please start a new session."

        /// a job session the runner creates itself, a workspace it can name, and
        /// an `echo` tool it can dispatch.
        static func harness(
            client: JobScriptClient
        ) async throws -> (app: AppState, store: FileSessionStore, workspace: URL) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-a8-job-\(UUID().uuidString)", isDirectory: true)
            let workspace = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let store = FileSessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))

            var echo = StubTool(name: "echo", toolset: "test")
            echo.handler = { args in "echo: \(args["value"] as? String ?? "")" }

            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [preset]
            f.settings.activeConfig = preset.name
            f.settings.workspaces = [WorkspaceEntry(name: "main", path: workspace.path)]
            f.settings.activeWorkspace = "main"
            f.settings.disabledToolsets = []
            f.registryTools = [echo, StubTool(name: "skill_view", toolset: "skills")]
            f.activeTabID = "logs"
            let app = AppState(renderFixture: f)
            await app.bindJobHarness(store: store, client: client)
            return (app, store, workspace)
        }

        static func job() -> CronJob {
            CronJob(name: "nightly report", schedule: "30m", prompt: "write the nightly report")
        }

        @Test("a job runs on the per-turn agent, stores its transcript and returns its output")
        func runsOnTheOneEngine() async throws {
            let client = JobScriptClient(mode: .toolThenFinal)
            let (app, store, workspace) = try await Self.harness(client: client)
            let job = Self.job()

            let output = await app.runScheduledJob(job)

            // 1. lastOutput: the final assistant text.
            #expect(output == "Job done.")

            // 2. per-message persistence: the job session holds the same
            //    transcript shape a chat turn writes, tool-call id included.
            let sid = await app.jobSessionID(job)
            let stored = try #require(try await store.get(id: sid))
            let roles: [Message.Role] = [.user, .assistant, .tool, .assistant]
            #expect(stored.messages.map(\.role) == roles,
                    "user prompt, the tool round, then the answer")
            #expect(stored.messages.first?.content == job.prompt)
            #expect(stored.messages[1].toolCalls?.map(\.function.name) == ["echo"])
            #expect(stored.messages[2].name == "echo")
            #expect(stored.messages[2].content == "echo: alpha")
            #expect(stored.messages[2].toolCallID == "call-echo-1",
                    "the stored tool result carries the id the model declared")
            #expect(stored.messages[3].content == "Job done.")

            // 3. the title: a new job session is named for the job.
            let titles = await app.settings.sessionTitles
            #expect(titles[sid] == "Cron: nightly report")

            // 4. one engine: the model-facing prompt is the core's tiered
            //    builder, and the environment names the job's workspace root.
            let firstRequest = try #require(client.captured.first)
            let system = try #require(firstRequest.first?.content)
            #expect(system.contains("You are ARC Agent"), "the core's identity preamble")
            #expect(!system.contains("Active configuration"),
                    "the retired UI builder's line never comes back")
            #expect(system.contains("Working directory for tools (relative paths resolve here): \(workspace.path)"),
                    "the job's agent is bound to the job session's workspace")
            #expect(firstRequest.contains { $0.role == .user && $0.content == job.prompt },
                    "the job prompt is the user turn")
        }

        @Test("a job keeps its own 25-round ceiling")
        func keepsTheIterationCap() async throws {
            let client = JobScriptClient(mode: .alwaysTool)
            let (app, store, _) = try await Self.harness(client: client)
            let job = Self.job()

            let output = await app.runScheduledJob(job)

            #expect(client.captured.count == 25,
                    "the retired loop's 25 iterations survive as the agent's maxIterations")
            #expect(output == Self.limitText)

            let sid = await app.jobSessionID(job)
            let stored = try #require(try await store.get(id: sid))
            #expect(stored.messages.last?.terminalReason == "max_iterations",
                    "the status card reads the core's terminal reason")
            #expect(stored.messages.last?.content == Self.limitText)
        }
    }
}

private extension AppState {
    /// bind the job's durable store and its scripted provider — the two vars the
    /// production init fills from the runtime.
    func bindJobHarness(store: any SessionStore, client: any LLMClient) {
        self.store = store
        self.turnClientOverride = client
    }
}