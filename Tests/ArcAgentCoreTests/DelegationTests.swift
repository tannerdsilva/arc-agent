import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - Parent/child-aware scripted LLM client
// =========================================================================

/// A scripted client that acts as the ORCHESTRATOR for the parent agent and
/// as an autonomous child-agent for delegation children (branching on the
/// child prompt, which starts with "You are a focused subagent").
///
/// Parent mode:
/// - turn 1 (no tool result yet): call `delegate_task` with a goal that
///   references ``filePath``.
/// - turn 2 (tool result present): echo the child's summary.
///
/// Child mode (subagent prompt present):
/// - turn 1: call `read_file` on ``filePath``.
/// - turn 2: report the file content, noting whether a `[steer: …]` message
///   was drained.
struct ParentAwareScriptedClient: LLMClient {

    let filePath: String
    let steerProbe: Bool

    init(filePath: String, steerProbe: Bool = false) {
        self.filePath = filePath
        self.steerProbe = steerProbe
    }

    private func isChild(_ messages: [Message]) -> Bool {
        messages.first { $0.role == .user }?.content?.hasPrefix("You are a focused subagent") ?? false
    }

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        isChild(messages) ? childTurn(messages) : parentTurn(messages)
    }

    private func childTurn(_ messages: [Message]) -> LLMResponse {
        if messages.contains(where: { $0.role == .tool }) {
            if steerProbe {
                let steered = messages.contains { $0.content?.contains("[steer:") == true }
                return LLMResponse(content: steered ? "steer received" : "no steer")
            }
            let toolResult = messages.last { $0.role == .tool }?.content ?? ""
            return LLMResponse(content: "The file contains: \(toolResult)")
        }
        return LLMResponse(
            content: nil,
            toolCalls: [ToolCall(id: "c1", function: ToolCallFunction(
                name: "read_file",
                arguments: #"{"path":"\#(filePath)"}"#
            ))]
        )
    }

    private func parentTurn(_ messages: [Message]) -> LLMResponse {
        if let toolResult = messages.last(where: { $0.role == .tool })?.content {
            return LLMResponse(content: "Child said: \(toolResult)")
        }
        return LLMResponse(
            content: nil,
            toolCalls: [ToolCall(id: "p1", function: ToolCallFunction(
                name: "delegate_task",
                arguments: #"{"goal":"Read the file at \#(filePath) and report its content","allowed_toolsets":"file"}"#
            ))]
        )
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        let response = isChild(messages) ? childTurn(messages) : parentTurn(messages)
        return AsyncThrowingStream { continuation in
            if let content = response.content {
                continuation.yield(LLMDelta(content: content))
            }
            if let calls = response.toolCalls {
                for (index, call) in calls.enumerated() {
                    continuation.yield(LLMDelta(
                        content: nil,
                        toolCalls: [ToolCallDelta(
                            index: index,
                            id: call.id,
                            name: call.function.name,
                            arguments: call.function.arguments
                        )]
                    ))
                }
            }
            continuation.finish()
        }
    }
}

/// A slow scripted client: never completes before ``sleepSeconds``, used to
/// keep a child running long enough to cancel deterministically.
struct SlowScriptedClient: LLMClient {

    let sleepSeconds: UInt64

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        try await Task.sleep(nanoseconds: sleepSeconds * 1_000_000_000)
        return LLMResponse(content: "slow done")
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: sleepSeconds * 1_000_000_000)
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else {
                    continuation.yield(LLMDelta(content: "slow done"))
                    continuation.finish()
                }
            }
        }
    }
}

// =========================================================================
// MARK: - Delegation tests
// =========================================================================

extension ArcCoreTestRoot {
    @Suite("Delegation", .serialized)
    struct DelegationTests {

        private func makeParentConfig(
            filePath: String,
            steerProbe: Bool = false,
            llmClient: (any LLMClient)? = nil,
            dependencies: ToolDependencies = ToolDependencies()
        ) throws -> ArcAgent.Configuration {
            let registry = try ArcAgentCore.testRegistry(dependencies: dependencies)
            return ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "k",
                registry: registry,
                sessionStore: VolatileSessionStore(),
                memoryProvider: nil,
                skills: [],
                maxIterations: 5,
                maxTurnDuration: 60,
                persistSessions: false,
                approvalMode: .off,
                maxContextTokens: 64_000,
                delegation: DelegationConfig(maxConcurrentChildren: 4, maxTurns: 5, defaultTimeout: 60),
                llmClient: llmClient ?? ParentAwareScriptedClient(filePath: filePath, steerProbe: steerProbe)
            )
        }

        private func primeAgent(_ config: ArcAgent.Configuration) async throws -> ArcAgent {
            let agent = ArcAgent(config: config)
            try await agent.prime()
            return agent
        }

        @Test("delegate_task returns the child's real final answer")
        func delegationReturnsRealSummary() async throws {
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-delegation-\(UUID().uuidString).txt")
            try "42".write(to: target, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: target) }

            let agent = try await primeAgent(try makeParentConfig(filePath: target.path))

            let response = try await agent.runConversation(
                message: "Use your delegation tool to read the file and report its content."
            )
            await agent.shutdownHTTPClient()

            // The parent must relay the child's ACTUAL tool result — not the old
            // stub's synthesized "Completed: <goal prefix 80>".
            #expect(response.contains("42"), "parent should relay the child's real summary, got: \(response)")
            #expect(response.contains("Child said"), "parent should wrap the child's summary, got: \(response)")
        }

        @Test("child registry strips the delegation toolset (no recursion)")
        func childRegistryStripsDelegation() throws {
            let registry = try ArcAgentCore.testRegistry()
            let parent = ArcAgent.Configuration(
                model: "m",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "k",
                registry: registry,
                sessionStore: VolatileSessionStore(),
                memoryProvider: nil,
                maxIterations: 5
            )

            // No allowedToolsets → inherit everything EXCEPT the delegation toolset.
            let inherited = DelegationManager.makeChildConfiguration(
                parent: parent, goal: "g", context: "", allowedToolsets: [], maxTurns: 5
            )
            #expect(inherited.disabledToolsets.contains("delegation"))
            #expect(!inherited.disabledToolsets.contains("file"))
            #expect(!inherited.disabledToolsets.contains("terminal"))

            // Explicit toolsets → intersection, plus the always-blocked set.
            let fileOnly = DelegationManager.makeChildConfiguration(
                parent: parent, goal: "g", context: "", allowedToolsets: ["file"], maxTurns: 5
            )
            #expect(fileOnly.disabledToolsets.contains("delegation"))
            #expect(fileOnly.disabledToolsets.contains("terminal"))
            #expect(!fileOnly.disabledToolsets.contains("file"))
        }

        @Test("steering is delivered to a running child")
        func steeringReachesChild() async throws {
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-delegate-steer-\(UUID().uuidString).txt")
            try "1".write(to: target, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: target) }

            let deps = ToolDependencies()
            let agent = try await primeAgent(try makeParentConfig(
                filePath: target.path, steerProbe: true, dependencies: deps))
            // The slot the tool reads, filled by the agent — not a process
            // global the next agent would overwrite (GROUNDZERO slice 6).
            guard let manager = deps.delegationManager.get() else {
                Issue.record("manager slot not wired by the agent")
                return
            }

            let id = try await manager.spawn(
                goal: "Read the file at \(target.path) and report its content",
                context: "",
                allowedToolsets: ["file"]
            )
            try await manager.steer(id: id, message: "URGENT please continue")

            guard let stream = await manager.stream(id: id) else {
                Issue.record("no stream")
                return
            }
            var result = ""
            for try await chunk in stream { result += chunk }
            await agent.shutdownHTTPClient()
            #expect(result.contains("steer received"), "child should drain the steer, got: \(result)")
        }

        @Test("cancel stops a running child and marks it cancelled")
        func cancelStopsChild() async throws {
            let deps = ToolDependencies()
            let agent = try await primeAgent(try makeParentConfig(
                filePath: "/tmp/never-read.txt",
                llmClient: SlowScriptedClient(sleepSeconds: 5),
                dependencies: deps
            ))
            guard let manager = deps.delegationManager.get() else {
                Issue.record("manager slot not wired by the agent")
                return
            }

            let id = try await manager.spawn(goal: "slow task", allowedToolsets: [])
            try await Task.sleep(nanoseconds: 200_000_000)  // let the child start
            guard let stream = await manager.stream(id: id) else {
                Issue.record("no stream")
                await agent.shutdownHTTPClient()
                return
            }
            try await manager.cancel(id: id)
            await agent.shutdownHTTPClient()

            let status = await manager.agent(id: id)?.status
            #expect(status == .cancelled)

            var result = ""
            for try await chunk in stream { result += chunk }
            #expect(result.contains("Cancelled"))
        }

        @Test("concurrency cap throws tooManyChildren")
        func concurrencyCap() async throws {
            let registry = try ArcAgentCore.testRegistry()
            let parent = ArcAgent.Configuration(
                model: "m",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "k",
                registry: registry,
                sessionStore: VolatileSessionStore(),
                memoryProvider: nil,
                maxIterations: 5,
                llmClient: SlowScriptedClient(sleepSeconds: 5)
            )
            let capped = DelegationManager(maxChildren: 1, parentConfiguration: parent)
            _ = try await capped.spawn(goal: "slow first", allowedToolsets: [])
            await #expect(throws: DelegationError.self) {
                _ = try await capped.spawn(goal: "second", allowedToolsets: [])
            }
            await capped.cancelAll()
        }
    }
}
