import Testing
import Foundation
@testable import ArcAgentCore

/// Tests for the MoA service, config, and trace (Hermes moa_loop parity).
@Suite("Mixture of Agents")
struct MoATests {

    struct FakeClient: LLMClient {
        let responses: [String: LLMResponse]
        var recordedMessages: [String] = []
        mutating func record(_ messages: [Message]) { recordedMessages = messages.compactMap { $0.content } }

        func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
            var client = self
            client.record(messages)
            return client.responses[messages.last?.content ?? ""] ?? LLMResponse(content: "advice", finishReason: "stop")
        }

        func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
            AsyncThrowingStream { c in
                c.yield(LLMDelta(content: "advice"))
                c.yield(LLMDelta(content: nil, finishReason: "stop"))
                c.finish()
            }
        }
    }

    // MARK: - Config

    @Test("moa config decodes Hermes snake_case keys")
    func configDecode() throws {
        let json = """
        {"moa": {"enabled": true, "reference_models": [{"model": "claude-sonnet-4-5", "provider": "anthropic", "temperature": 0.3}],
                  "aggregator": {"model": "gpt-5"}, "aggregator_temperature": 0.2,
                  "reference_max_tokens": 4096, "degraded_reference_policy": "silent"}}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ArcConfig.self, from: json)
        #expect(config.moa.enabled)
        #expect(config.moa.referenceModels.count == 1)
        #expect(config.moa.referenceModels[0].model == "claude-sonnet-4-5")
        #expect(config.moa.referenceModels[0].provider == "anthropic")
        #expect(config.moa.referenceModels[0].temperature == 0.3)
        #expect(config.moa.aggregator?.model == "gpt-5")
        #expect(config.moa.aggregatorTemperature == 0.2)
        #expect(config.moa.referenceMaxTokens == 4096)
        #expect(config.moa.degradedReferencePolicy == "silent")
    }

    @Test("moa config tolerates absence and malformed entries")
    func configTolerant() {
        let empty = MoAConfig.from(nil)
        #expect(!empty.enabled)
        let partial = MoAConfig.from(["enabled": true, "reference_models": [
            ["model": "a"], ["provider": "b"] // missing model → dropped
        ]])
        #expect(partial.enabled)
        #expect(partial.referenceModels.count == 1)
        #expect(partial.degradedReferencePolicy == "loud")
    }

    // MARK: - Advisory view

    @Test("advisory view appends instruction after assistant turns (Hermes _ADVISORY_INSTRUCTION)")
    func advisoryAppend() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "help"],
            ["role": "assistant", "content": "checking…"],
        ]
        let view = MoAService.advisoryMessages(apiMessages: messages, userPrompt: "help")
        #expect((view.last?["role"] as? String) == "user")
        #expect((view.last?["content"] as? String) == MoAPrompts.advisoryInstruction)
    }

    @Test("advisory view preserves tool calls and results")
    func advisoryTools() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "run it"],
            ["role": "assistant", "tool_calls": [
                ["function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]],
            ]],
            ["role": "tool", "content": "file.txt"],
        ]
        let view = MoAService.advisoryMessages(apiMessages: messages, userPrompt: "run it")
        let joined = view.map { "\($0["role"] ?? ""):\($0["content"] ?? "")" }.joined(separator: "|")
        #expect(joined.contains("[tool call] terminal"))
        #expect(joined.contains("[tool result] file.txt"))
        // Ends on the tool-result turn (user role), so no advisory marker is
        // appended — the reference answers the current state directly.
        #expect((view.last?["content"] as? String) == "[tool result] file.txt")
    }

    @Test("advisory view falls back to the user prompt when empty")
    func advisoryFallback() {
        let view = MoAService.advisoryMessages(apiMessages: [], userPrompt: "orig")
        #expect(view.count == 1)
        #expect((view[0]["content"] as? String) == "orig")
    }

    // MARK: - Aggregate

    @Test("aggregate joins reference advice as `Reference N — label` blocks")
    func aggregateJoin() async {
        let config = MoAConfig(
            enabled: true,
            referenceModels: [
                .init(model: "ref-a"),
                .init(model: "ref-b"),
            ],
            degradedReferencePolicy: "loud"
        )
        let service = MoAService(config: config) { role, _ in
            FakeClient(responses: [:])
        }
        let result = await service.aggregate(
            userPrompt: "hi",
            apiMessages: [["role": "user", "content": "hi"]]
        )
        #expect(result.advisoryBlock.contains("Reference 1 — ref-a:"))
        #expect(result.advisoryBlock.contains("Reference 2 — ref-b:"))
        #expect(result.advisoryBlock.contains("advice"))
        #expect(result.trace.referenceResults.count == 2)
        #expect(result.trace.referenceResults.allSatisfy { $0.status == "ok" })
        #expect(result.trace.aggregatorModel == nil)
    }

    @Test("failed references become loud notes instead of aborting (Hermes degraded policy)")
    func aggregateFailureNotes() async {
        let config = MoAConfig(
            enabled: true,
            referenceModels: [.init(model: "ref-a"), .init(model: "ref-b")],
            degradedReferencePolicy: "loud"
        )
        let service = MoAService(config: config) { role, _ in
            if role.model == "ref-a" {
                return FakeClient(responses: [:])
            }
            throw LLMError.timeout(1)
        }
        let result = await service.aggregate(
            userPrompt: "hi",
            apiMessages: [["role": "user", "content": "hi"]]
        )
        #expect(result.advisoryBlock.contains("failed:"))
        #expect(result.advisoryBlock.contains("ref-b"))
        #expect(result.advisoryBlock.contains("Reference 1 — ref-a:"))
        #expect(result.trace.referenceResults[1].status == "failed")
    }

    @Test("silent degraded policy omits failure notes")
    func aggregateSilent() async {
        let config = MoAConfig(
            enabled: true,
            referenceModels: [.init(model: "ref-a")],
            degradedReferencePolicy: "silent"
        )
        let service = MoAService(config: config) { role, _ in
            if role.model == "ref-a" { throw LLMError.timeout(1) }
            return FakeClient(responses: [:])
        }
        let result = await service.aggregate(
            userPrompt: "hi",
            apiMessages: [["role": "user", "content": "hi"]]
        )
        #expect(!result.advisoryBlock.contains("failed:"))
        #expect(result.notes.count == 1)
    }

    @Test("disabled config yields an empty block without running references")
    func aggregateDisabled() async {
        let service = MoAService(config: MoAConfig()) { role, _ in
            FakeClient(responses: [:])
        }
        let result = await service.aggregate(
            userPrompt: "hi",
            apiMessages: [["role": "user", "content": "hi"]]
        )
        #expect(result.advisoryBlock.isEmpty)
        #expect(result.trace.referenceResults.isEmpty)
    }

    @Test("reference fan-out is capped at maxConcurrentReferences")
    func fanOutCap() async {
        let models = (0..<12).map { MoAConfig.Role(model: "ref-\($0)") }
        let config = MoAConfig(enabled: true, referenceModels: models, maxConcurrentReferences: 5)
        let service = MoAService(config: config) { role, _ in
            FakeClient(responses: [:])
        }
        let result = await service.aggregate(
            userPrompt: "hi",
            apiMessages: [["role": "user", "content": "hi"]]
        )
        #expect(result.trace.referenceResults.count == 5)
    }

    // MARK: - Trace

    @Test("moa trace JSON carries reference statuses")
    func traceJSON() {
        let trace = MoATrace(
            turnID: "turn-1",
            referenceResults: [
                MoAReferenceResult(label: "ref-a", model: "m1", status: "ok", outputTokens: 10,
                                   durationMs: 5, error: nil, text: "advice"),
                MoAReferenceResult(label: "ref-b", model: "m2", status: "failed", outputTokens: nil,
                                   durationMs: 2, error: "boom", text: nil),
            ],
            aggregatorModel: "agg"
        )
        let json = trace.asJSON
        #expect(json["turn_id"] as? String == "turn-1")
        #expect(json["aggregator_model"] as? String == "agg")
        let refs = json["references"] as? [[String: Any]]
        #expect(refs?.count == 2)
        #expect((refs?[1]["status"] as? String) == "failed")
        #expect(refs?[1]["error"] as? String == "boom")
    }
}
