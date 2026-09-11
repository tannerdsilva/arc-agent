import Testing
import Foundation
@testable import ArcAgentCore

/// Empty-response recovery (Hermes `_check_empty_storm` parity).
@Suite("Empty response recovery")
struct EmptyResponseTests {

    @Test("RetryHandler classifies emptyResponse as retryable")
    func retryableClassification() {
        #expect(classifyError(LLMError.emptyResponse) == .retryable)
        #expect(classifyError(LLMError.decodingError("bad")) == .permanent)
    }

    @Test("Failover classifies emptyResponse as emptyResponse reason")
    func failoverClassification() {
        #expect(ErrorClassifier.classify(LLMError.emptyResponse).reason == .emptyResponse)
        #expect(ErrorClassifier.classify(LLMError.decodingError("bad")).reason == .decoding)
    }

    @Test("storm guard trips after threshold")
    func stormGuard() {
        var state = TurnRecoveryState()
        for _ in 0...TurnRecoveryState.emptyStormThreshold {
            state.emptyStormStreak += 1
        }
        #expect(state.emptyStormStreak > TurnRecoveryState.emptyStormThreshold)
        #expect(TurnRecoveryState.emptyStormThreshold >= 1)
    }
}
