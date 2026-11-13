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
        case alwaysFails
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
        if mode == .alwaysFails {
            return AsyncThrowingStream { $0.finish(throwing: LLMError.apiError(statusCode: 500, message: "scripted failure")) }
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
            case .alwaysTool, .alwaysFails:
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
            f.arcConfig.tools.disabledToolsets = []
            f.registryTools = [echo, StubTool(name: "skill_view", toolset: "skills")]
            f.activeTabID = "logs"
            let app = AppState(renderFixture: f)
            // Hermetic cron store: the default is the process-wide
            // RuntimeCronStore, which resolves to the production tessera
            // relay whenever it is running — a test saving through it would
            // deposit its fixture jobs ("nightly report", "Job done.") into
            // the live store, where the UI would resurrect them forever.
            let cron = FileCronStore(directory: root.appendingPathComponent("cron", isDirectory: true))
            await app.bindJobHarness(store: store, client: client, cron: cron)
            return (app, store, workspace)
        }

        static func job() -> CronJob {
            CronJob(name: "nightly report", schedule: "30m", prompt: "write the nightly report")
        }

        @Test("the job harness never touches the production cron store")
        func cronStoreIsHermetic() async throws {
            let client = JobScriptClient(mode: .toolThenFinal)
            let (app, _, _) = try await Self.harness(client: client)
            // Regression: the harness used to leave the default
            // RuntimeCronStore in place — with the relay running, every
            // `app.cronStore.save` published a fixture job ("nightly
            // report" / "Job done.") into the production tessera store,
            // and the Tasks page resurrected it on every restart.
            let boundStore = await app.cronStore
            #expect(boundStore is FileCronStore,
                    "bindJobHarness must bind a hermetic store, not the live RuntimeCronStore")
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

        @Test("Run-now arms asynchronously and stamps the record off-path")
        func runNowDoesNotBlockAndStampsCorrectly() async throws {
            let client = JobScriptClient(mode: .toolThenFinal)
            let (app, _, _) = try await Self.harness(client: client)
            // A one-shot whose instant is in the far future — the shape that
            // used to re-arm itself into Active forever.
            var job = Self.job()
            job.schedule = "2099-01-01T00:00:00Z"
            try await app.cronStore.save(job)
            await app.refreshScheduledJobs()

            await app.runJobNow(job.id)
            #expect(await app.runningCronJobs.contains(job.id),
                    "the run is flagged before the handler returns")

            // The turn runs off-path; wait for it to land (the scripted
            // client completes in milliseconds).
            for _ in 0..<100 {
                if !(await app.runningCronJobs.contains(job.id)) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(await app.runningCronJobs.isEmpty, "the flag clears on completion")
            let final = try #require(try await app.cronStore.get(id: job.id))
            #expect(final.runCount == 1)
            #expect(final.lastStatus == "ok")
            #expect(final.nextRunAt == nil,
                    "a fired one-shot is never re-armed, even from the UI path")
            #expect(final.lastOutput == "Job done.")
        }

        // MARK: script jobs (§6.2): SwiftSlash, never a session turn

        @Test("a script job runs through SwiftSlash — no LLM, mirrored transcript")
        func scriptJobBypassesTheLLM() async throws {
            let client = JobScriptClient(mode: .toolThenFinal)
            let (app, store, _) = try await Self.harness(client: client)
            var job = Self.job()
            job.script = "echo script-echo-ok"

            let output = await app.runScheduledJob(job)

            // The shell line ran; the LLM never saw a single request.
            #expect(output == "script-echo-ok")
            #expect(client.captured.isEmpty, "a script job never mints a turn agent")

            // The job's chat mirrors the script and its result.
            let sid = await app.jobSessionID(job)
            let stored = try #require(try await store.get(id: sid))
            let roles: [Message.Role] = [.user, .assistant]
            #expect(stored.messages.map(\.role) == roles)
            #expect(stored.messages[0].content == "$ echo script-echo-ok")
            #expect(stored.messages[1].content == "script-echo-ok")
        }

        @Test("a failing script job's exit status surfaces as the output")
        func scriptJobFailureSurfaces() async throws {
            let client = JobScriptClient(mode: .toolThenFinal)
            let (app, store, _) = try await Self.harness(client: client)
            var job = Self.job()
            job.script = "exit 3"

            let output = await app.runScheduledJob(job)

            #expect(output.contains("exit 3"), "the failure alert becomes the output")
            #expect(client.captured.isEmpty)
            #expect(await app.lastScheduledRunFailed, "the run is stamped failed")
            let sid = await app.jobSessionID(job)
            let stored = try #require(try await store.get(id: sid))
            #expect(stored.messages.count == 2, "script + failure alert")
            #expect(stored.messages[1].content?.contains("exit 3") == true)
        }

        @Test("a silent script job says nothing but still mirrors the run")
        func silentScriptJobStaysSilent() async throws {
            let client = JobScriptClient(mode: .toolThenFinal)
            let (app, store, _) = try await Self.harness(client: client)
            var job = Self.job()
            job.script = "true"

            let output = await app.runScheduledJob(job)

            #expect(output == "", "silence stays silent — no delivered text")
            #expect(client.captured.isEmpty)
            let sid = await app.jobSessionID(job)
            let stored = try #require(try await store.get(id: sid))
            #expect(stored.messages.map(\.role) == [.user],
                    "the script is mirrored; there is no result to say")
        }

        @Test("Run-now counts a successful run against the budget and retires the job")
        func runNowConsumesBudget() async throws {
            let client = JobScriptClient(mode: .toolThenFinal)
            let (app, _, _) = try await Self.harness(client: client)
            var job = Self.job()
            job.schedule = "" // manual job, budget 1 — Idle then Completed
            job.runBudget = 1
            try await app.cronStore.save(job)
            await app.refreshScheduledJobs()

            await app.runJobNow(job.id)
            for _ in 0..<100 {
                if !(await app.runningCronJobs.contains(job.id)) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let final = try #require(try await app.cronStore.get(id: job.id))
            #expect(final.runCount == 1)
            #expect(final.runsRemaining == 0, "the successful run consumed the budget")
            #expect(final.isActive == false, "the job self-retires at zero")
            let cat = await app.taskCategory(for: final)
            #expect(cat == .completed, "a budget-spent job settles into Completed")
        }

        @Test("the sync tick surfaces out-of-band scheduler writes; idle pages push nothing")
        func syncTickLiveness() async throws {
            let client = JobScriptClient(mode: .toolThenFinal)
            let (app, _, _) = try await Self.harness(client: client)
            var job = Self.job()
            job.runBudget = 3
            try await app.cronStore.save(job)
            await app.refreshScheduledJobs()
            // An idle store: the tick must report no change (no push traffic).
            #expect(await app.syncScheduledJobs() == false, "nothing moved — no push")

            // A scheduler fire lands out-of-band: bump the record directly in
            // the store WITHOUT going through the app's writers — exactly the
            // daemon's write shape.
            var fired = try #require(try await app.cronStore.get(id: job.id))
            fired.runCount = 1
            fired.lastStatus = "ok"
            fired.runsRemaining = 2
            fired.lastRunAt = Date()
            fired.nextRunAt = Date().addingTimeInterval(1800)
            try await app.cronStore.save(fired)

            #expect(await app.syncScheduledJobs() == true, "the scheduler write moved the fingerprint")
            let cached = await app.settings.scheduledJobs.first { $0.id == job.id }
            #expect(cached?.runsRemaining == 2, "the render cache now carries the scheduler's count")
            let cat = await app.taskCategory(for: cached!)
            #expect(cat == .activePending, "budget not yet spent — still Active/Pending")
        }

        @Test("a failed Run-now stamps lastStatus error, not ok")
        func runNowFailureStampsError() async throws {
            // A scripted client whose stream throws — the same shape as a
            // transport failure mid-turn.
            let client = JobScriptClient(mode: .alwaysFails)
            let (app, _, _) = try await Self.harness(client: client)
            var job = Self.job()
            job.schedule = "0 9 * * *"
            try await app.cronStore.save(job)
            await app.refreshScheduledJobs()
            await app.runJobNow(job.id)
            for _ in 0..<100 {
                if !(await app.runningCronJobs.contains(job.id)) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let final = try #require(try await app.cronStore.get(id: job.id))
            #expect(final.lastStatus == "error")
            #expect(final.runCount == 1, "the attempt still counts")
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
    /// bind the job's durable store, its scripted provider and its cron
    /// store — the vars the production init fills from the runtime. The
    /// cron store MUST be hermetic: the default ``RuntimeCronStore``
    /// publishes to the production relay when one is reachable.
    func bindJobHarness(store: any SessionStore, client: any LLMClient,
                        cron: any CronStore) {
        self.store = store
        self.turnClientOverride = client
        self.cronStore = cron
    }
}