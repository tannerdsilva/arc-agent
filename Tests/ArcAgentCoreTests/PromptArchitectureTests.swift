import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

/// Hermes-parity prompt architecture tests: token-budget completeness,
/// cache-tiered system prompt, project context injection, skills framing,
/// compression guards, wire laundering, steer/interrupt, and session_search.
@Suite("Prompt Architecture")
struct PromptArchitectureTests {

    // MARK: - Helpers

    private func tempStore() -> FileSessionStore {
        FileSessionStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-prompt-arch-\(UUID().uuidString)")
        )
    }

    private func makeConfig(
        registry: CompileTimeToolRegistry = CompileTimeToolRegistry(),
        store: (any SessionStore)? = nil,
        sessionID: String? = nil,
        persistSessions: Bool = false,
        contextLength: Int? = nil,
        maxContextTokens: Int = 64_000,
        contextDirectory: URL? = nil,
        injectProjectContext: Bool = true,
        skills: [Skill] = [],
        fallbackAPIKeys: [String] = []
    ) -> ArcAgent.Configuration {
        ArcAgent.Configuration(
            model: "test-model",
            provider: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "test-key",
            registry: registry,
            sessionStore: store ?? tempStore(),
            memoryProvider: nil,
            skills: skills,
            maxIterations: 10,
            maxTurnDuration: 30,
            persistSessions: persistSessions,
            approvalMode: .off,
            query: nil,
            maxContextTokens: maxContextTokens,
            sessionID: sessionID,
            contextLength: contextLength,
            fallbackAPIKeys: fallbackAPIKeys,
            injectProjectContext: injectProjectContext,
            contextDirectory: contextDirectory,
            platformHint: "cli"
        )
    }

    private func runOnce(_ config: ArcAgent.Configuration, box: ClientScripts) async throws -> String {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let agent = ArcAgent(config: config)
        await agent.setupClient(httpClient: httpClient)
        await agent.setClient(ScriptedClient(box: box))
        return try await agent.runConversation(message: "hello")
    }

    // MARK: - Token budget (P0)

    @Test("effectiveContextLimit is 50% of model context length")
    func effectiveContextLimitUsesModelContext() {
        let withCtx = makeConfig(contextLength: 100_000)
        let nilCtx = makeConfig()
        let agentA = ArcAgent(config: withCtx)
        let agentB = ArcAgent(config: nilCtx)
        #expect(agentA.effectiveContextLimit() == 50_000)
        #expect(agentB.effectiveContextLimit() == 64_000)
    }

    @Test("compression triggers on FULL estimate (context files + schemas) and rebuilds the prompt")
    func compressionUsesFullEstimate() async throws {
        // Tiny context length (limit 60) + restored history: compression must
        // fire and produce an extractive summary (no aux override in tests).
        let store = tempStore()
        let sid = "compress-me"
        var initial: [Message] = []
        for i in 0..<20 {
            initial.append(Message(role: .user, content: "old user \(i)"))
            initial.append(Message(role: .assistant, content: "old answer \(i)"))
        }
        try await store.create(Session(id: sid, model: "m", provider: "p", messages: initial))

        let box = ClientScripts(responses: [LLMResponse(content: "done", finishReason: "stop")])
        let config = makeConfig(
            store: store, sessionID: sid, persistSessions: false,
            contextLength: 300, maxContextTokens: 64_000,
            injectProjectContext: false
        )
        _ = try await runOnce(config, box: box)

        let calls = box.recordedCalls()
        #expect(calls.count == 1, "expected exactly one LLM call")
        guard let sent = calls.first else { return }
        // Summary system message must be present, and history must contain
        // only head (2) + tail (~4) + the new user message.
        let summary = sent.filter {
            $0.role == .system
                && ($0.content ?? "").hasPrefix(ArcAgent.compressionSummaryPrefix)
        }
        #expect(summary.count == 1, "expected a compression summary; got \(sent.map(\.role))")
        #expect(sent.filter { $0.role != .system }.count <= 8,
            "tail protection failed: \(sent.filter { $0.role != .system }.count) non-system messages")
        // The system prompt was rebuilt after compression (timestamp present).
        let prompt = sent.first(where: { $0.role == .system })?.content ?? ""
        #expect(prompt.contains("Conversation started:"))
    }

    @Test("sanitize applied on restore: orphaned tool results are dropped")
    func restoreSanitizesOrphans() async throws {
        let store = tempStore()
        let sid = "orphan"
        try await store.create(Session(id: sid, messages: [
            Message(role: .user, content: "hi"),
            Message(role: .tool, content: "orphaned result", name: "read_file", toolCallID: "ghost"),
            Message(role: .assistant, content: "answer"),
        ]))
        let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
        let config = makeConfig(store: store, sessionID: sid)
        _ = try await runOnce(config, box: box)
        let sent = box.recordedCalls().first ?? []
        #expect(!sent.contains { $0.role == .tool },
            "orphaned tool result must be laundered out of restored history")
    }

    // MARK: - Prompt tiers, context files, skills framing (P1)

    @Test("system prompt is tiered: tools -> context files -> skills -> session line")
    func promptTiers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arc-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let agentsURL = dir.appendingPathComponent("AGENTS.md")
        try "REPO LAW: be excellent.".write(to: agentsURL, atomically: true, encoding: .utf8)

        let skills = [
            Skill(name: "alpha", description: "first skill description", content: "c", category: "dev", path: dir),
            Skill(name: "beta", description: "second skill description", content: "c", category: nil, path: dir),
        ]
        let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
        let config = makeConfig(contextDirectory: dir, injectProjectContext: true, skills: skills)
        _ = try await runOnce(config, box: box)

        guard let prompt = box.recordedCalls().first?.first(where: { $0.role == .system })?.content else {
            Issue.record("no system prompt recorded"); return
        }
        #expect(prompt.contains("## Skills (mandatory)"))
        #expect(prompt.contains("you MUST load it with skill_view(name)"))
        #expect(prompt.contains("<available_skills>"))
        #expect(prompt.contains("### dev"))
        #expect(prompt.contains("- `alpha`:"))
        #expect(prompt.contains("- `beta`:"))
        #expect(prompt.contains("## Workspace & Project Context"))
        #expect(prompt.contains("### AGENTS.md"))
        #expect(prompt.contains("REPO LAW"))
        #expect(prompt.contains("Conversation started:"))
        #expect(prompt.contains("Platform: cli"))

        let toolsIdx = prompt.range(of: "## Available Tools")!.lowerBound
        let ctxIdx = prompt.range(of: "## Workspace & Project Context")!.lowerBound
        let skillsIdx = prompt.range(of: "## Skills (mandatory)")!.lowerBound
        let tsIdx = prompt.range(of: "Conversation started:")!.lowerBound
        #expect(toolsIdx < ctxIdx, "stable tier must precede context tier")
        #expect(ctxIdx < skillsIdx, "context tier must precede volatile tier")
        #expect(skillsIdx < tsIdx, "session line must be last")
    }

    @Test("skills index is category-grouped (Hermes parity)")
    func skillsIndexGrouped() {
        let skills = [
            Skill(name: "alpha", description: "first skill description", content: "c", category: "dev", path: URL(fileURLWithPath: "/tmp")),
            Skill(name: "beta", description: "second skill description", content: "c", category: "dev", path: URL(fileURLWithPath: "/tmp")),
            Skill(name: "gamma", description: "third skill description", content: "c", category: "devops", path: URL(fileURLWithPath: "/tmp")),
        ]
        let index = buildSkillsIndex(skills)
        #expect(index.contains("### dev"))
        #expect(index.contains("### devops"))
        #expect(index.contains("- `alpha`:"))
        #expect(!index.contains("[dev]"), "legacy bracket category prefix must be gone")
    }

    // MARK: - Wire laundering (P2)

    @Test("sanitize drops orphans, adds stubs, strips thinking-only, merges users")
    func sanitizeShapesHistory() {
        let messages: [Message] = [
            Message(role: .user, content: "part one"),
            Message(role: .assistant, content: " ", toolCalls: nil), // thinking-only
            Message(role: .user, content: "part two"),
            Message(role: .tool, content: "orphan", toolCallID: "ghost"),
            Message(role: .assistant, content: nil, toolCalls: [
                ToolCall(id: "2", function: ToolCallFunction(name: "read_file", arguments: "{ \"path\" : \"/tmp/x\" }")),
            ]),
            Message(role: .tool, content: "token: sk-abcdefghijklmnopqrstuvwxyz123456", toolCallID: "2"),
            Message(role: .assistant, content: nil, toolCalls: [
                ToolCall(id: "1", function: ToolCallFunction(name: "write_file", arguments: "{ \"path\": \"/tmp/y\" }")),
            ]),
            Message(role: .assistant, content: "final"),
        ]
        let cleaned = ArcAgent.sanitizeMessages(messages)

        // Orphan dropped.
        #expect(!cleaned.contains { $0.content == "orphan" }, "orphan tool result must be dropped")
        // Thinking-only dropped (it followed a user, so the next user merges).
        #expect(!cleaned.contains { $0.content == " " }, "thinking-only assistant turn must be dropped")
        #expect(cleaned.filter { $0.role == .user }.count == 1)
        let user = cleaned.first { $0.role == .user }
        #expect(user?.content?.contains("part one") == true && user?.content?.contains("part two") == true)
        // Arguments canonicalized (Foundation escapes "/" as "\/").
        let assistant2 = cleaned.first { $0.role == .assistant && $0.toolCalls?.first?.id == "2" }
        #expect(assistant2?.toolCalls?.first?.function.arguments == "{\"path\":\"\\/tmp\\/x\"}",
            "args must be re-serialized deterministically: \(assistant2?.toolCalls?.first?.function.arguments ?? "nil")")
        // Legit tool result stays but is redacted.
        let tool2 = cleaned.first { $0.role == .tool && $0.toolCallID == "2" }
        #expect(tool2 != nil, "matching tool result must survive")
        #expect(tool2?.content?.contains("REDACTED") == true, "secrets must be redacted from tool results")
        #expect(tool2?.content?.contains("sk-abcdefghijklmnopqrstuvwxyz123456") != true)
        // Stub added for the missing result (matching id "1").
        #expect(cleaned.contains { $0.role == .tool && $0.toolCallID == "1" })
    }

    @Test("redactSecrets covers API keys, GH tokens, AWS keys, bearer, private keys")
    func redactSecretsPatterns() {
        let sample = "ghp_1234567890abcdefghij and sk-abcdefghijklmnopqrstuvwxyz123456 and AKIA1234567890ABCDEF and Bearer abcdefghijklmnop and -----BEGIN RSA PRIVATE KEY-----"
        let out = ArcAgent.redactSecrets(sample)
        #expect(!out.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        #expect(out.contains("***REDACTED***"))
        #expect(!out.contains("ghp_1234567890abcdefghij"))
        #expect(!out.contains("AKIA1234567890ABCDEF"))
        #expect(!out.contains("BEGIN RSA PRIVATE KEY"))
        // Plain prose is untouched.
        #expect(ArcAgent.redactSecrets("the weather is fine") == "the weather is fine")
    }

    @Test("invalid tool-call arguments canonicalize to empty object")
    func canonicalizeInvalidArgs() {
        let call = ToolCall(id: "1", function: ToolCallFunction(name: "x", arguments: "{not json"))
        let out = ArcAgent.sanitizeMessages([
            Message(role: .assistant, content: nil, toolCalls: [call]),
        ])
        #expect(out.first?.toolCalls?.first?.function.arguments == "{}")
    }

    // MARK: - Steer & interrupt (P3)

    @Test("steer drains into the next LLM request")
    func steerDrains() async throws {
        let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
        let config = makeConfig(persistSessions: false, injectProjectContext: false)
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let agent = ArcAgent(config: config)
        await agent.setupClient(httpClient: httpClient)
        await agent.setClient(ScriptedClient(box: box))
        await agent.steer("use the red path")
        _ = try await agent.runConversation(message: "hello")
        let sent = box.recordedCalls().first ?? []
        #expect(sent.contains { $0.role == .user && ($0.content ?? "").contains("use the red path") },
            "steer must be visible to the model: \(sent.map(\.content))")
    }

    @Test("interrupt aborts the turn at the iteration boundary")
    func interruptAborts() async throws {
        let box = ClientScripts(responses: [LLMResponse(content: "never", finishReason: "stop")])
        let config = makeConfig(persistSessions: false, injectProjectContext: false)
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }
        let agent = ArcAgent(config: config)
        await agent.setupClient(httpClient: httpClient)
        await agent.setClient(ScriptedClient(box: box))
        await agent.interruptTurn()
        let out = try await agent.runConversation(message: "hello")
        #expect(out == "Interrupted by user.")
        #expect(box.recordedCalls().isEmpty, "interrupted turn must not call the LLM")
    }

    // MARK: - Session search tool (P3)

    @Test("session_search finds past sessions through the wired store")
    func sessionSearchFinds() async throws {
        let store = tempStore()
        try await store.create(Session(id: "remembered", messages: [
            Message(role: .user, content: "we built the foobar bridge"),
            Message(role: .assistant, content: "yes and foobar is green"),
        ]))
        SessionSearchTool.store = store
        defer { SessionSearchTool.store = nil }
        let result = try await SessionSearchTool.entry.handler(["query": "foobar"])
        #expect(result.contains("remember"), "expected session id prefix in result: \(result)")
        #expect(result.contains("foobar bridge"))
        let empty = try await SessionSearchTool.entry.handler(["query": "zzz-no-match"])
        #expect(empty.contains("No sessions matched"))
    }

    @Test("session title round-trips through Codable")
    func sessionTitleRoundTrips() throws {
        let session = Session(id: "t1", title: "Titled", messages: [])
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.title == "Titled")
        let untitled = Session(id: "t2")
        #expect(untitled.title == nil)
    }
}
