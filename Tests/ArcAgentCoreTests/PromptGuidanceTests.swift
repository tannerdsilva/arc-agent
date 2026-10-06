import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

/// Prompt-guidance parity tests: universal task-completion, parallel-tool-call
/// and tool-aware (memory/session_search/skills) guidance blocks injected into
/// the stable system-prompt tier, plus their config gates.
@Suite("Prompt Guidance", .serialized)
struct PromptGuidanceTests {

    // MARK: - Helpers

    private func tempStore() -> FileSessionStore {
        FileSessionStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-prompt-guidance-\\(UUID().uuidString)")
        )
    }

    private func makeConfig(
        registry: any ToolRegistry,
        taskCompletionGuidance: Bool = true,
        parallelToolCallGuidance: Bool = true,
        toolAwareGuidance: Bool = true
    ) -> ArcAgent.Configuration {
        ArcAgent.Configuration(
            model: "test-model",
            provider: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "test-key",
            registry: registry,
            sessionStore: tempStore(),
            memoryProvider: nil,
            skills: [],
            maxIterations: 10,
            maxTurnDuration: 30,
            persistSessions: false,
            approvalMode: .off,
            query: nil,
            maxContextTokens: 64_000,
            taskCompletionGuidance: taskCompletionGuidance,
            parallelToolCallGuidance: parallelToolCallGuidance,
            toolAwareGuidance: toolAwareGuidance,
            sessionID: "guidance-test",
            injectProjectContext: false,
            platformHint: "cli"
        )
    }

    private func runOnce(_ config: ArcAgent.Configuration) async throws -> String {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown() }
        let box = ClientScripts(responses: [
            LLMResponse(content: "ok", finishReason: "stop"),
        ])
        let agent = ArcAgent(config: config)
        await agent.setupClient(httpClient: httpClient)
        await agent.setClient(ScriptedClient(box: box))
        _ = try await agent.runConversation(message: "hello")
        guard let sent = box.recordedCalls().first else { return "" }
        return sent.first(where: { $0.role == .system })?.content ?? ""
    }

    // MARK: - Default: guidance present

    @Test("default prompt contains task-completion, parallel-call and tool-aware guidance")
    func defaultPromptHasGuidance() async throws {
        let prompt = try await runOnce(makeConfig(registry: try ArcAgentCore.buildDefaultRegistry()))
        #expect(prompt.contains("## Finishing the job"))
        #expect(prompt.contains("substitute plausible-looking fabricated output"))
        #expect(prompt.contains("## Parallel tool calls"))
        #expect(prompt.contains("batch them"))
        // Tool-aware (default registry has memory / session_search / skills tools).
        #expect(prompt.contains("persistent memory across sessions"))
        #expect(prompt.contains("use session_search to recall it before asking"))
        #expect(prompt.contains("skill_manage(action='patch')"))
    }

    @Test("guidance drops out when config gates are off")
    func configGatesOff() async throws {
        let prompt = try await runOnce(makeConfig(
            registry: try ArcAgentCore.buildDefaultRegistry(),
            taskCompletionGuidance: false,
            parallelToolCallGuidance: false,
            toolAwareGuidance: false
        ))
        #expect(!prompt.contains("## Finishing the job"))
        #expect(!prompt.contains("## Parallel tool calls"))
        #expect(!prompt.contains("persistent memory across sessions"))
        #expect(!prompt.contains("skill_manage(action='patch')"))
        // Prompt still exists and keeps its stable scaffolds.
        #expect(prompt.contains("You are ARC Agent"))
        #expect(prompt.contains("## Rules"))
    }

    @Test("tool-aware guidance is gated by the registry, not the flag")
    func toolAwareGatingByTools() async throws {
        // Empty registry: memory/session_search/skill tools absent → no tool-aware
        // guidance, but the universal blocks still land.
        let emptyRegistry = CompileTimeToolRegistry()
        let prompt = try await runOnce(makeConfig(registry: emptyRegistry))
        #expect(prompt.contains("## Finishing the job"))
        #expect(prompt.contains("## Parallel tool calls"))
        #expect(!prompt.contains("persistent memory across sessions"))
        #expect(!prompt.contains("skill_manage(action='patch')"))
    }

    @Test("AgentConfig guidance flags decode with ON defaults")
    func agentConfigDecodeDefaults() throws {
        let empty = try JSONDecoder().decode(ArcConfig.self, from: Data(#"{"agent":{}}"#.utf8))
        #expect(empty.agent.taskCompletionGuidance)
        #expect(empty.agent.parallelToolCallGuidance)
        #expect(empty.agent.toolAwareGuidance)

        let off = try JSONDecoder().decode(ArcConfig.self, from: Data(#"{"agent":{"taskCompletionGuidance":false,"parallelToolCallGuidance":false,"toolAwareGuidance":false}}"#.utf8))
        #expect(!off.agent.taskCompletionGuidance)
        #expect(!off.agent.parallelToolCallGuidance)
        #expect(!off.agent.toolAwareGuidance)
    }
}
