import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

// =========================================================================
// MARK: - Mock LLM

/// A scripted, stateless ``LLMClient`` for integration tests.
///
/// Turn 1 (no tool result in the history yet) responds with a `read_file`
/// tool call against ``filePath``. Turn 2 (a tool result is present)
/// returns the file content as the final answer.
struct ScriptedLLMClient: LLMClient {

    let filePath: String

    /// Call the LLM and require tool schemas on every invocation. Fails the
    /// turn loop if the registry did not pass schemas through.
    private func assertSchemas(_ tools: [[String: Any]]?) throws {
        guard let tools, !tools.isEmpty else {
            throw LLMError.decodingError("ScriptedLLMClient: expected tool schemas")
        }
    }

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        try assertSchemas(tools)
        if let toolResult = messages.last(where: { $0.role == .tool })?.content {
            return LLMResponse(content: "The file contains: \(toolResult)")
        }
        return LLMResponse(
            content: nil,
            toolCalls: [
                ToolCall(
                    id: "call_1",
                    function: ToolCallFunction(
                        name: "read_file",
                        arguments: #"{"path":"\#(filePath)"}"#
                    )
                )
            ]
        )
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        // Compute the sendable inputs up front; the stream closure captures
        // only Sendable values (an `Error`, a `String?`, and this struct).
        let toolResult = messages.last(where: { $0.role == .tool })?.content
        let schemaError: Error?
        do {
            try assertSchemas(tools)
            schemaError = nil
        } catch {
            schemaError = error
        }
        let filePath = self.filePath

        return AsyncThrowingStream { continuation in
            Task {
                if let schemaError {
                    continuation.finish(throwing: schemaError)
                    return
                }
                if let toolResult {
                    for chunk in ["The ", "file ", "contains: ", "\(toolResult)"] {
                        continuation.yield(LLMDelta(content: chunk))
                    }
                } else {
                    continuation.yield(LLMDelta(
                        content: nil,
                        toolCalls: [
                            ToolCallDelta(
                                index: 0,
                                id: "call_1",
                                name: "read_file",
                                arguments: #"{"path":"\#(filePath)"}"#
                            )
                        ]
                    ))
                }
                continuation.finish()
            }
        }
    }
}

// =========================================================================
// MARK: - Agent Integration (mock LLM → tool → response)

@Suite("Agent Integration")
struct AgentIntegrationTests {

    private func makeAgent(
        registry: CompileTimeToolRegistry,
        httpClient: HTTPClient
    ) async -> ArcAgent {
        let config = ArcAgent.Configuration(
            model: "test-model",
            provider: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "",
            registry: registry,
            skills: [],
            maxIterations: 5,
            maxTurnDuration: 30,
            persistSessions: false,
            approvalMode: .manual,
            query: nil,
            maxContextTokens: 64_000
        )
        let agent = ArcAgent(config: config)
        await agent.setupClient(httpClient: httpClient)
        return agent
    }

    @Test("completion path: tool call executes against the real registry and answer returns")
    func completionPathExecutesTool() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-agent-test-\(UUID().uuidString).txt")
        try "integration payload 42".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: target) }

        // The agent's HTTP client is only needed for the default client and
        // fallback path; the scripted mock covers the LLM calls.
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient)
        await agent.setClient(ScriptedLLMClient(filePath: target.path))

        let response = try await agent.runConversation(message: "Read the file at \(target.path)")

        // The mock's turn-2 answer embeds the tool result, proving the
        // registry handler really executed read_file against the file.
        #expect(response.contains("integration payload 42"), "expected tool result in final answer, got: \(response)")
    }

    @Test("streaming path: deltas stream and tool result reach the final answer")
    func streamingPathExecutesTool() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-agent-stream-\(UUID().uuidString).txt")
        try "stream payload 99".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: target) }

        let registry = try ArcAgentCore.buildDefaultRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient)
        await agent.setClient(ScriptedLLMClient(filePath: target.path))

        let stream = await agent.streamConversation(message: "What is in \(target.path)?")
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        let full = chunks.joined()
        #expect(chunks.count >= 4, "expected streamed deltas, got \(chunks.count)")
        #expect(full.contains("stream payload 99"), "expected tool result in streamed answer, got: \(full)")
    }

    @Test("registry without the requested tool reports an error instead of crashing")
    func missingToolReturnsError() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { httpClient.shutdown() }

        // A registry that has NOTHING — the mock will still request read_file.
        let registry = CompileTimeToolRegistry()
        let agent = await makeAgent(registry: registry, httpClient: httpClient)
        await agent.setClient(ScriptedLLMClient(filePath: "/nonexistent/x.txt"))

        let response = try await agent.runConversation(message: "Read it.")

        // dispatchToolCall must surface a structured error, not crash.
        #expect(!response.isEmpty)
        #expect(response != "The conversation reached the maximum iteration limit. Please start a new session.")
    }
}
