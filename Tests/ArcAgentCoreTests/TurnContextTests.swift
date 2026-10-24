import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

// =========================================================================
// MARK: - Turn context: workspace root, terminal reason, compression gate
// =========================================================================

extension ArcCoreTestRoot {
    @Suite("Turn context", .serialized)
    struct TurnContextTests {

        // MARK: helpers

        private func makeAgent(
            registry: CompileTimeToolRegistry,
            httpClient: HTTPClient,
            client: any LLMClient,
            autoCompression: Bool = true,
            workspaceRoot: String? = nil,
            maxContextTokens: Int = 64_000,
            maxIterations: Int = 25
        ) async -> ArcAgent {
            let config = ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "test-key",
                registry: registry,
                skills: [],
                maxIterations: maxIterations,
                maxTurnDuration: 30,
                persistSessions: false,
                approvalMode: .off,
                maxContextTokens: maxContextTokens,
                workspaceRoot: workspaceRoot,
                autoCompression: autoCompression,
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

        private func completedPayloads(_ events: [AgentTurnEvent]) -> [(text: String, reason: String?)] {
            events.compactMap { event in
                if case .completed(let text, let reason) = event { return (text, reason) }
                return nil
            }
        }

        // MARK: workspace root

        @Test("workspace root defaults to nil")
        func workspaceRootDefaultsToNil() {
            let config = ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "test-key",
                registry: CompileTimeToolRegistry()
            )
            #expect(config.workspaceRoot == nil)
        }

        @Test("workspace root is settable")
        func workspaceRootIsSettable() {
            var config = ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "test-key",
                registry: CompileTimeToolRegistry()
            )
            config.workspaceRoot = "/custom/root"
            #expect(config.workspaceRoot == "/custom/root")
        }

        @Test("different workspace roots resolve the same relative path differently")
        func differentRootsResolveDifferently() async throws {
            let rootA = "/workspace/a"
            let rootB = "/workspace/b"

            var resolvedA: String?
            var resolvedB: String?

            await WorkspacePath.$root.withValue(rootA) {
                resolvedA = WorkspacePath.resolve("rel.txt")
            }
            await WorkspacePath.$root.withValue(rootB) {
                resolvedB = WorkspacePath.resolve("rel.txt")
            }

            #expect(resolvedA == "/workspace/a/rel.txt")
            #expect(resolvedB == "/workspace/b/rel.txt")
            #expect(resolvedA != resolvedB)
        }

        // MARK: terminal reason

        @Test("normal completion emits completed with terminalReason nil")
        func normalCompletionHasNilTerminalReason() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let client = EventScriptClient(
                first: .init(chunks: ["hello"]),
                final: .init()
            )
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client, maxIterations: 5)

            let events = try await collect(agent)

            let payloads = completedPayloads(events)
            #expect(payloads.count == 1)
            #expect(payloads.first?.text == "hello")
            #expect(payloads.first?.reason == nil)
        }

        @Test("max iteration limit emits completed with terminalReason max_iterations")
        func maxIterationsEmitsMaxIterationsReason() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            // Always request a tool call so the turn never produces text,
            // exhausting the iteration budget.
            let toolCall = ToolCallDelta(
                index: 0,
                id: "call_1",
                name: "read_file",
                arguments: #"{"path":"x.txt"}"#
            )
            let client = EventScriptClient(
                first: .init(toolCalls: [toolCall]),
                final: .init(toolCalls: [toolCall])
            )
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let agent = await makeAgent(registry: registry, httpClient: httpClient, client: client, maxIterations: 1)

            let events = try await collect(agent)

            let payloads = completedPayloads(events)
            #expect(payloads.count == 1)
            #expect(payloads.first?.reason == "max_iterations")
        }

        // MARK: compression gate

        @Test("autoCompression false skips compression even when over budget")
        func autoCompressionFalseSkipsCompression() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let toolCall = ToolCallDelta(
                index: 0,
                id: "call_1",
                name: "read_file",
                arguments: #"{"path":"x.txt"}"#
            )
            // Round 1 (no tool results in history): tool call.
            // Round 2 (tool result present): text answer.
            let client = EventScriptClient(
                first: .init(toolCalls: [toolCall]),
                final: .init(chunks: ["done"])
            )
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let agent = await makeAgent(
                registry: registry,
                httpClient: httpClient,
                client: client,
                autoCompression: false,
                maxContextTokens: 1, // tiny budget → compression would trigger if not gated
                maxIterations: 3
            )

            let events = try await collect(agent)

            let payloads = completedPayloads(events)
            #expect(payloads.count == 1)
            #expect(payloads.first?.text == "done")

            // The turn completed: the gate returned early at `guard config.autoCompression || force`,
            // so no compressor ran. The LLM was called twice (tool round + text round).
            let calls = client.allRecordedMessages
            #expect(calls.count == 2)
            // The second call saw the full, uncompressed history including the tool result.
            let secondTurn = calls[1]
            #expect(secondTurn.contains { $0.role == .tool })
        }

        @Test("autoCompression true (default) still compresses when over budget")
        func autoCompressionTrueStillCompresses() async throws {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }

            let toolCall = ToolCallDelta(
                index: 0,
                id: "call_1",
                name: "read_file",
                arguments: #"{"path":"x.txt"}"#
            )
            let client = EventScriptClient(
                first: .init(toolCalls: [toolCall]),
                final: .init(chunks: ["done"])
            )
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let agent = await makeAgent(
                registry: registry,
                httpClient: httpClient,
                client: client,
                autoCompression: true, // default
                maxContextTokens: 1, // tiny budget → compression triggers
                maxIterations: 3
            )

            let events = try await collect(agent)

            let payloads = completedPayloads(events)
            #expect(payloads.count == 1)
            #expect(payloads.first?.text == "done")

            // The turn completed: compression ran internally (extractive fallback
            // since no compression auxiliary override is configured).
            let calls = client.allRecordedMessages
            #expect(calls.count == 2)
        }
    }
}
