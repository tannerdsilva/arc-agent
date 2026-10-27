import Testing
@testable import ArcAgentCore
import Foundation

/// Compression visibility: the engine must honor an explicit per-profile
/// compression budget (single source of truth with the UI meter) and must
/// emit a visible `.compressing` turn event while a compression pass runs.
extension ArcCoreTestRoot {
    @Suite("Compression budget & visibility")
    struct CompressionBudgetTests {

        private func makeConfig(
            compressionBudget: Int?,
            contextLength: Int?,
            maxContextTokens: Int = 64_000
        ) -> ArcAgent.Configuration {
            ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "",
                registry: CompileTimeToolRegistry(),
                skills: [],
                maxContextTokens: maxContextTokens,
                contextLength: contextLength,
                compressionBudget: compressionBudget
            )
        }

        @Test("effectiveContextLimit honors an explicit compression budget")
        func explicitBudgetWins() async {
            let agent = ArcAgent(config: makeConfig(compressionBudget: 12_345, contextLength: 100_000))
            #expect(await agent.effectiveContextLimit() == 12_345)
        }

        @Test("default threshold is half the context length (arc parity)")
        func defaultIsHalfContext() async {
            let agent = ArcAgent(config: makeConfig(compressionBudget: nil, contextLength: 100_000))
            #expect(await agent.effectiveContextLimit() == 50_000)
        }

        @Test("no explicit budget and no context length: falls back to maxContextTokens")
        func fallbackUsesMaxContextTokens() async {
            let agent = ArcAgent(config: makeConfig(compressionBudget: nil, contextLength: nil, maxContextTokens: 21_000))
            #expect(await agent.effectiveContextLimit() == 21_000)
        }

        @Test("forced compression emits a .compressing turn event")
        func compressingEventEmitted() async {
            let agent = ArcAgent(config: makeConfig(compressionBudget: nil, contextLength: 100_000))
            let events = ThreadSafeArray<AgentTurnEvent>()
            await agent.autoCompressIfNeeded(emit: { events.append($0) }, force: true)
            #expect(events.all.contains { event in
                if case .compressing = event { return true }
                return false
            })
        }

        @Test("no compression: no .compressing event")
        func noCompressingWhenUnderLimit() async {
            let agent = ArcAgent(config: makeConfig(compressionBudget: nil, contextLength: 100_000))
            let events = ThreadSafeArray<AgentTurnEvent>()
            await agent.autoCompressIfNeeded(emit: { events.append($0) }, force: false)
            #expect(events.all.isEmpty)
        }
    }
}

/// Minimal sendable array for capture inside @Sendable emit closures.
final class ThreadSafeArray<T>: @unchecked Sendable {
    private var items: [T] = []
    var all: [T] { items }
    func append(_ item: T) { items.append(item) }
}
