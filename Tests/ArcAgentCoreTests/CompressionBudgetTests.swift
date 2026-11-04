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
            maxContextTokens: Int = 64_000,
            maxOutputTokens: Int? = nil
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
                compressionBudget: compressionBudget,
                maxOutputTokens: maxOutputTokens
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

        @Test("maxOutputTokens reservation leaves an under-window budget untouched")
        func reservationUnderBudgetUntouched() async {
            // 599k window, 130k budget, 32k reserved for output: the budget
            // sits well below the usable window, so it passes through.
            let agent = ArcAgent(config: makeConfig(
                compressionBudget: 130_000, contextLength: 599_040, maxOutputTokens: 32_000))
            #expect(await agent.effectiveContextLimit() == 130_000)
        }

        @Test("large maxOutputTokens clamps the threshold to 85% of the usable window")
        func reservationClampsTo85Percent() async {
            // 100k window with 90k reserved: only 10k of input budget remains,
            // so a 50%-of-window threshold (50k) could never be reached — the
            // provider would reject the request first. Clamp to 85% of 10k.
            let agent = ArcAgent(config: makeConfig(
                compressionBudget: nil, contextLength: 100_000, maxOutputTokens: 90_000))
            #expect(await agent.effectiveContextLimit() == 8_500)
        }

        @Test("explicit budget at or over the usable window clamps the same way")
        func explicitBudgetClamped() async {
            let agent = ArcAgent(config: makeConfig(
                compressionBudget: 95_000, contextLength: 100_000, maxOutputTokens: 20_000))
            #expect(await agent.effectiveContextLimit() == 68_000) // 85% of 80k
        }

        @Test("reservation larger than the window halves the base as a last resort")
        func oversizedReservationHalves() async {
            // Window fully consumed by the reservation (usable <= 0): no
            // meaningful input budget exists, so halve the base as a last
            // resort rather than returning an unreachable threshold.
            let agent = ArcAgent(config: makeConfig(
                compressionBudget: nil, contextLength: 10_000, maxOutputTokens: 20_000))
            #expect(await agent.effectiveContextLimit() == 2_500)
        }

        @Test("scaffold estimate is positive and stable (cached system prompt)")
        func scaffoldEstimateStable() async {
            let agent = ArcAgent(config: makeConfig(compressionBudget: nil, contextLength: 100_000))
            let first = await agent.estimateScaffoldTokens()
            #expect(first > 0)
            let second = await agent.estimateScaffoldTokens()
            #expect(first == second)
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

        @Test("inverted output reservation is detected; sane config is not")
        func invertedOutputReservationDetection() {
            // maxOutputTokens ≥ window: the reservation consumes the entire
            // window and the effective limit collapses to the half-budget
            // fallback — the greeting-chat failure shape.
            let inverted = ArcAgent(config: makeConfig(
                compressionBudget: 10_000, contextLength: 20_480, maxOutputTokens: 512_000))
            let pair = inverted.invertedOutputReservation()
            #expect(pair?.maxOutputTokens == 512_000)
            #expect(pair?.contextWindow == 20_480)

            // Reservation under the window: no warning.
            let sane = ArcAgent(config: makeConfig(
                compressionBudget: 10_000, contextLength: 20_480, maxOutputTokens: 4_096))
            #expect(sane.invertedOutputReservation() == nil)

            // No maxOutputTokens configured: nothing to invert.
            let unset = ArcAgent(config: makeConfig(
                compressionBudget: 10_000, contextLength: 20_480))
            #expect(unset.invertedOutputReservation() == nil)
        }

        @Test("inverted reservation emits .outputReservationExceedsWindow once")
        func outputReservationEventEmittedOnce() async {
            let agent = ArcAgent(config: makeConfig(
                compressionBudget: 10_000, contextLength: 20_480, maxOutputTokens: 512_000))
            let events = ThreadSafeArray<AgentTurnEvent>()
            await agent.noteOutputReservationForTest(emit: { events.append($0) })
            await agent.noteOutputReservationForTest(emit: { events.append($0) })
            #expect(events.all.count == 1, "expected exactly one reservation event; got \(events.all.count)")
            if case .outputReservationExceedsWindow(let maxTokens, let window) = events.all.first {
                #expect(maxTokens == 512_000)
                #expect(window == 20_480)
            } else {
                Issue.record("missing reservation event payload")
            }
        }

        @Test("overhead wall emits a .contextConstrained turn event once")
        func contextConstrainedEventEmitted() async {
            // Scaffold (real registry, ~800) over a tiny limit: the engine
            // minimizes and raises the wall event exactly once per agent.
            let agent = ArcAgent(config: makeConfig(
                compressionBudget: nil, contextLength: 300, maxContextTokens: 64_000))
            let events = ThreadSafeArray<AgentTurnEvent>()
            await agent.autoCompressIfNeeded(emit: { events.append($0) }, force: true)
            await agent.autoCompressIfNeeded(emit: { events.append($0) }, force: true)
            let wallEvents = events.all.filter { event in
                if case .contextConstrained = event { return true }
                return false
            }
            #expect(wallEvents.count == 1, "expected exactly one wall event; got \(wallEvents.count)")
            if case .contextConstrained(let scaffold, let limit) = wallEvents.first {
                #expect(scaffold >= limit)
            } else {
                Issue.record("missing wall event payload")
            }
        }
    }
}

/// Minimal sendable array for capture inside @Sendable emit closures.
final class ThreadSafeArray<T>: @unchecked Sendable {
    private var items: [T] = []
    var all: [T] { items }
    func append(_ item: T) { items.append(item) }
}
