import Testing
import Foundation
@testable import ArcAgentCore

/// Tests for the usage/pricing/insights/trace layer (Hermes usage_pricing,
/// credits_tracker, insights, trace_upload parity).
@Suite("Usage & pricing")
struct UsageTests {

    @Test("canonical usage addition is component-wise")
    func usageAdd() {
        let a = CanonicalUsage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 2, cacheWriteTokens: 1, reasoningTokens: 3, requestCount: 1)
        let b = CanonicalUsage(inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4, reasoningTokens: 5, requestCount: 1)
        let sum = a + b
        #expect(sum.inputTokens == 11)
        #expect(sum.outputTokens == 7)
        #expect(sum.cacheReadTokens == 5)
        #expect(sum.requestCount == 2)
        #expect(sum == CanonicalUsage(inputTokens: 11, outputTokens: 7, cacheReadTokens: 5, cacheWriteTokens: 5, reasoningTokens: 8, requestCount: 2))
    }

    @Test("pricing: exact match, prefix match, unknown model returns zero cost")
    func pricing() {
        let route = BillingRoute(provider: "openai", model: "gpt-4o")
        let result = UsagePricing.estimate(
            route: route,
            usage: CanonicalUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        )
        #expect(result.cost == 12.50) // 2.50 + 10.00
        #expect(result.matchedModel == "gpt-4o")
        #expect(result.source == "official")

        let prefixed = UsagePricing.estimate(
            route: BillingRoute(provider: "anthropic", model: "claude-sonnet-4-5-20250929"),
            usage: CanonicalUsage(inputTokens: 1_000_000)
        )
        #expect(prefixed.matchedModel == "claude-sonnet-4-5")
        #expect(prefixed.cost == 3.00)

        let unknown = UsagePricing.estimate(
            route: BillingRoute(provider: "openai", model: "my-custom-model"),
            usage: CanonicalUsage(inputTokens: 100)
        )
        #expect(unknown.cost == 0)
        #expect(unknown.matchedModel == nil)
    }

    @Test("cache-read pricing applies when the table provides it")
    func cachePricing() {
        let route = BillingRoute(provider: "openai", model: "gpt-4o")
        let result = UsagePricing.estimate(
            route: route,
            usage: CanonicalUsage(inputTokens: 1_000_000, cacheReadTokens: 1_000_000)
        )
        #expect(result.cost == 2.50 + 1.25)
    }

    @Test("compact token format (Hermes format_token_count_compact)")
    func compact() {
        #expect(UsagePricing.formatCompact(999) == "999")
        #expect(UsagePricing.formatCompact(1_200) == "1.2K")
        #expect(UsagePricing.formatCompact(12_000) == "12K")
        #expect(UsagePricing.formatCompact(3_400_000) == "3.4M")
    }

    @Test("ledger persists per-day buckets, routes, and cost (local JSON)")
    func ledger() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        let ledger = UsageLedger(fileURL: url)
        await ledger.record(
            route: BillingRoute(provider: "openai", model: "gpt-4o", baseURL: "https://api.openai.com/v1"),
            usage: CanonicalUsage(inputTokens: 1_000_000, outputTokens: 500_000, requestCount: 1)
        )
        let today = UsageLedger.dayString()
        let day = await ledger.day(today)
        #expect(day?.usage.inputTokens == 1_000_000)
        #expect(day?.byRoute["openai/gpt-4o"]?.outputTokens == 500_000)
        #expect(abs((await ledger.totalCost()) - 7.50) < 0.0001)
        #expect((await ledger.total()).requestCount == 1)

        // Reload from disk — persistence round-trips.
        let reloaded = UsageLedger(fileURL: url)
        let day2 = await reloaded.day(today)
        #expect(day2?.usage.inputTokens == 1_000_000)
    }

    @Test("insights: daily rows and top-model ranking")
    func insights() {
        let day1 = UsageDay(date: "2026-09-09", usage: CanonicalUsage(inputTokens: 100, outputTokens: 50, requestCount: 1), byRoute: ["a/m1": CanonicalUsage(inputTokens: 100, outputTokens: 50, requestCount: 1)])
        let day2 = UsageDay(date: "2026-09-10", usage: CanonicalUsage(inputTokens: 500, outputTokens: 0, requestCount: 2), byRoute: ["b/m2": CanonicalUsage(inputTokens: 500, outputTokens: 0, requestCount: 2)])
        let daily = InsightsEngine.daily([day2, day1])
        #expect(daily.map { $0.date } == ["2026-09-09", "2026-09-10"])
        #expect(daily[0].tokens == 150)
        #expect(daily[1].requests == 2)

        let top = InsightsEngine.topModels([day1, day2])
        #expect(top.first?.route == "b/m2")
    }

    @Test("trace lines carry Claude-Code shape usage and timing")
    func traceShape() {
        let line = TraceUpload.traceLine(
            sessionID: "s1", timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            model: "gpt-4o", inputTokens: 100, outputTokens: 20, durationMs: 500, message: "hi")
        #expect(line["type"] as? String == "assistant")
        #expect(line["session_id"] as? String == "s1")
        #expect(line["duration_ms"] as? Int == 500)
        let usage = line["usage"] as? [String: Int]
        #expect(usage?["input_tokens"] == 100)
        #expect(usage?["output_tokens"] == 20)
    }
}
