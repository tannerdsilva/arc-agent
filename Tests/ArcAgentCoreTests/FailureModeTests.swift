import Testing
import Foundation
@testable import ArcAgentCore

/// Tests for the Hermes-parity failure-mode breadth: taxonomy, backoff,
/// staleness watchdogs, rate-limit tracking, and bounded recovery state.
@Suite("Failure modes")
struct FailureModeTests {

    // MARK: - ErrorClassifier

    @Test("auth and permanent-auth classification")
    func classifyAuth() {
        let auth = ErrorClassifier.classify(LLMError.authenticationFailed)
        #expect(auth.reason == .auth)
        #expect(!auth.reason.isRetryable)

        let revoked = ErrorClassifier.classify(LLMError.apiError(
            statusCode: 401, message: "invalid or expired API key"
        ))
        #expect(revoked.reason == .authPermanent)
    }

    @Test("rate limit and overload classification")
    func classifyLimits() {
        let limited = ErrorClassifier.classify(LLMError.rateLimited(retryAfter: 12))
        #expect(limited.reason == .rateLimit)
        #expect(limited.retryAfter == 12)
        #expect(limited.reason.isRetryable)

        let overload = ErrorClassifier.classify(LLMError.apiError(statusCode: 529, message: "overloaded"))
        #expect(overload.reason == .overloaded)
        #expect(overload.reason.isFallbackCandidate)
    }

    @Test("context-length and content-policy classification")
    func classifyContext() {
        let ctx = ErrorClassifier.classify(LLMError.apiError(
            statusCode: 400, message: "This model's maximum context length is 128000 tokens"
        ))
        #expect(ctx.reason == .contextLength)

        let policy = ErrorClassifier.classify(LLMError.contentPolicyViolation("blocked by safety"))
        #expect(policy.reason == .contentPolicy)
        #expect(!policy.reason.isRetryable)
    }

    @Test("transport errors classify as timeout/tls")
    func classifyTransport() {
        #expect(ErrorClassifier.classify(LLMError.networkError("connection reset")).reason == .timeout)
        let tls = ErrorClassifier.classify(NSError(domain: "NIO", code: 1,
                                                   userInfo: [NSLocalizedDescriptionKey: "TLS certificate expired"]))
        #expect(tls.reason == .tls)
        #expect(tls.tlsReason == .certificateExpired)
    }

    // MARK: - FailureBackoff

    @Test("backoff ladders: overload, server, rate-limit")
    func backoffLadders() {
        // Hermes ZAI overload ladder 30/60/90/120.
        #expect(FailureBackoff.delay(for: .overloaded, attempt: 0) == 30)
        #expect(FailureBackoff.delay(for: .overloaded, attempt: 1) == 60)
        #expect(FailureBackoff.delay(for: .overloaded, attempt: 3) == 120)
        #expect(FailureBackoff.delay(for: .overloaded, attempt: 9) == 120)

        // Rate limit honors retry-after.
        #expect(FailureBackoff.delay(for: .rateLimit, attempt: 0, retryAfter: 45) == 45)

        // Exponential is capped and jittered within ±20%.
        let d = FailureBackoff.delay(for: .serverError, attempt: 10)
        #expect(d <= 30 * 1.2)
        #expect(d >= 30 * 0.8)
    }

    // MARK: - StalenessPolicy

    @Test("stream patience scales with token estimate (@Hermes >50K → ≥240s, >100K → ≥300s)")
    func patienceScaling() {
        #expect(StalenessPolicy.streamPatience(estimatedTokens: 1_000, metadata: nil) == 180)
        #expect(StalenessPolicy.streamPatience(estimatedTokens: 60_000, metadata: nil) >= 240)
        #expect(StalenessPolicy.streamPatience(estimatedTokens: 120_000, metadata: nil) >= 300)
    }

    @Test("reasoning floor raises patience (Hermes reasoning_timeouts)")
    func reasoningFloor() {
        let meta = ModelMetadataRegistry.shared.metadata(for: "o3", provider: "openai")
        #expect(meta.staleTimeoutFloor == 300)
        #expect(StalenessPolicy.streamPatience(estimatedTokens: 100, metadata: meta) >= 300)
    }

    @Test("metadata registry: exact, family-prefix, and unknown fallbacks")
    func metadataLookup() {
        let registry = ModelMetadataRegistry.shared
        #expect(registry.metadata(for: "claude-sonnet-4-5", provider: "anthropic").cacheStyle == .anthropicCacheControl)
        #expect(registry.metadata(for: "claude-sonnet-4-5-20250929", provider: "anthropic").cacheStyle == .anthropicCacheControl)
        #expect(registry.metadata(for: "claude", provider: "anthropic").toolSchemaStyle == .anthropic)
        #expect(registry.metadata(for: "never-seen-model", provider: "unknown").contextLength == registry.defaultContextLength)
        // Config override wins.
        #expect(registry.metadata(for: "gpt-4o", provider: "openai", configuredContextLength: 999).contextLength == 999)
    }

    @Test("anthropic effort mapping: xhigh downgraded pre-4.7, offered on 4.5+")
    func effortMapping() {
        let registry = ModelMetadataRegistry.shared
        let sonnet = registry.metadata(for: "claude-sonnet-4-5", provider: "anthropic")
        let payload = registry.thinkingPayload(effort: "xhigh", metadata: sonnet)
        #expect((payload?["output_config"] as? [String: Any])?["effort"] as? String == "xhigh")

        let older = registry.metadata(for: "claude-sonnet-4", provider: "anthropic")
        let payloadLow = registry.thinkingPayload(effort: "xhigh", metadata: older)
        #expect((payloadLow?["output_config"] as? [String: Any])?["effort"] as? String == "max")
        #expect(registry.thinkingPayload(effort: "off", metadata: sonnet) == nil)
    }

    // MARK: - StaleStreakTracker

    @Test("stale streak give-up at 5 and reset on success")
    func staleStreak() async {
        let tracker = StaleStreakTracker()
        for i in 1...4 {
            #expect(await tracker.recordStale() == i)
            #expect(!(await tracker.shouldGiveUp))
        }
        #expect(await tracker.recordStale() == 5)
        #expect(await tracker.shouldGiveUp)
        await tracker.reset()
        #expect(!(await tracker.shouldGiveUp))
        #expect(await tracker.remainingBeforeGiveUp == 5)
    }

    // MARK: - IdleTimeoutStream

    @Test("idle stream passes elements through and finishes")
    func idleStreamPass() async throws {
        let base = AsyncThrowingStream<Int, Error> { c in
            c.yield(1); c.yield(2); c.yield(3); c.finish()
        }
        var collected: [Int] = []
        for try await n in IdleTimeoutStream(base, idleSeconds: 5) {
            collected.append(n)
        }
        #expect(collected == [1, 2, 3])
    }

    @Test("idle stream throws StaleStreamError on silence")
    func idleStreamStale() async {
        let base = AsyncThrowingStream<Int, Error> { c in
            c.yield(1)
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms silence
                c.yield(2)
                c.finish()
            }
        }
        var sawStale = false
        do {
            for try await _ in IdleTimeoutStream(base, idleSeconds: 0.05) {}
        } catch is StaleStreamError {
            sawStale = true
        } catch {
            #expect(Bool(false), "unexpected error \(error)")
        }
        #expect(sawStale)
    }

    // MARK: - RateLimitTracker

    @Test("rate limit tracker honors retry-after and computes usage")
    func rateLimitTracking() async {
        let tracker = RateLimitTracker()
        await tracker.recordThrottle(route: "openai/gpt-5", retryAfter: 42)
        let backoff = await tracker.backoffSeconds(route: "openai/gpt-5")
        #expect(backoff >= 42 * 0.9 && backoff <= 42 * 1.1)

        await tracker.record(WireTransport.RateLimitSnapshot(
            limit: 100, remaining: 10, resetSeconds: 60, resetAt: nil, usedPercent: 90
        ), route: "openai/gpt-5", retryAfter: nil)
        #expect(await tracker.usagePercent(route: "openai/gpt-5") == 90)
        await tracker.recordSuccess(route: "openai/gpt-5")
        #expect(await tracker.throttleStreak(route: "openai/gpt-5") == 0)
    }

    @Test("retry-after parsing: seconds and HTTP-date (Hermes parse_retry_after_seconds)")
    func retryAfterParsing() {
        #expect(WireTransport.parseRetryAfter("7") == 7)
        #expect(WireTransport.parseRetryAfter("garbage") == nil)
        // HTTP-date in the past clamps to 0. Future date yields positive.
        let future = Date().addingTimeInterval(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let parsed = WireTransport.parseRetryAfter(formatter.string(from: future))
        #expect(parsed != nil)
        #expect(parsed! > 0 && parsed! <= 61)
    }

    // MARK: - TurnRecoveryState

    @Test("turn recovery counters: invalid-JSON cap and storm threshold")
    func recoveryCounters() {
        var state = TurnRecoveryState()
        for _ in 0..<TurnRecoveryState.maxInvalidJSONRetries {
            state.invalidJSONRetries += 1
            #expect(state.invalidJSONRetries <= TurnRecoveryState.maxInvalidJSONRetries)
        }
        state.invalidJSONRetries += 1
        #expect(state.invalidJSONRetries > TurnRecoveryState.maxInvalidJSONRetries)

        state.markProviderSuccess()
        #expect(state.invalidJSONRetries == 0)
        #expect(state.emptyStormStreak == 0)

        for _ in 0..<TurnRecoveryState.emptyStormThreshold { state.emptyStormStreak += 1 }
        #expect(state.emptyStormStreak >= TurnRecoveryState.emptyStormThreshold)
    }

    @Test("recovery nudge texts carry Hermes semantics")
    func nudgeTexts() {
        let invalid = RecoveryNudges.invalidJSONToolResult(toolName: "read_file", error: "bad json")
        #expect(invalid.contains("Invalid JSON arguments"))
        #expect(invalid.contains("read_file"))
        #expect(invalid.contains("Retry"))

        let continuation = RecoveryNudges.continuationPrompt(droppedToolNames: ["terminal", "read_file"])
        #expect(continuation.contains("terminal, read_file"))
        #expect(continuation.contains("Continue exactly where you left off"))
    }

    // MARK: - Moonshot schema repair

    @Test("moonshot schema repair strips unsupported keys and empty required")
    func moonshotRepair() {
        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "read_file",
                "description": "Read a file",
                "parameters": [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": [] as [String],
                    "additionalProperties": false,
                ],
            ],
        ]
        let repaired = MoonshotSchema.sanitizeTools([tool])
        let params = (repaired[0]["function"] as? [String: Any])?["parameters"] as? [String: Any]
        #expect(params?["additionalProperties"] == nil)
        #expect(params?["required"] == nil)
        #expect(params?["type"] as? String == "object")
    }
}
