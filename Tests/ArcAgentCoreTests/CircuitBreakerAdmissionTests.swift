import Foundation
import Testing

@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// The breaker's whole purpose is to *stop* calling a dead endpoint for a
    /// while — and then to start again. The second half is the part that has to
    /// be on the admission path: `open` only becomes `halfOpen` when something
    /// asks "may I call?", and `currentState()` is a pure query.
    ///
    /// The agent used to read `currentState()` and throw when it said `open`,
    /// so once the breaker tripped it rejected every request for the life of
    /// the process — a 30-second provider outage disabled the agent until
    /// restart. These tests pin admission as the transition point.
    @Suite("Circuit breaker admission", .serialized)
    struct CircuitBreakerAdmissionTests {

        private func tripped(threshold: Int = 2, resetTimeout: TimeInterval = 0.05) async -> CircuitBreaker {
            let breaker = CircuitBreaker(label: "test", threshold: threshold, resetTimeout: resetTimeout)
            for _ in 0..<threshold {
                await breaker.recordFailure(LLMError.networkError("provider down"))
            }
            return breaker
        }

        @Test("an open breaker rejects calls inside the reset window")
        func rejectsInsideWindow() async throws {
            let breaker = await tripped()
            let state = await breaker.currentState()
            guard case .open = state else {
                Issue.record("expected .open after the threshold, got \(state)")
                return
            }
            await #expect(throws: CircuitBreakerError.self) {
                try await breaker.admit()
            }
        }

        @Test("an open breaker admits again once the window elapses")
        func admitsAfterWindow() async throws {
            let breaker = await tripped(resetTimeout: 0.05)
            try await Task.sleep(for: .milliseconds(120))

            // The admission itself performs open → half-open. A pure state read
            // here would leave the breaker open forever.
            try await breaker.admit()

            let state = await breaker.currentState()
            guard case .halfOpen = state else {
                Issue.record("expected .halfOpen after admission, got \(state)")
                return
            }
        }

        @Test("a successful probe closes the circuit and clears the failure count")
        func probeSuccessCloses() async throws {
            let breaker = await tripped(threshold: 1, resetTimeout: 0.01)
            try await Task.sleep(for: .milliseconds(40))
            try await breaker.admit()
            _ = try await breaker.call { 7 }
            let state = await breaker.currentState()
            guard case .closed = state else {
                Issue.record("expected .closed after a successful probe, got \(state)")
                return
            }
        }

        @Test("a failed probe reopens the circuit for another window")
        func probeFailureReopens() async throws {
            let breaker = await tripped(threshold: 1, resetTimeout: 0.01)
            try await Task.sleep(for: .milliseconds(40))
            try await breaker.admit()

            await #expect(throws: LLMError.self) {
                try await breaker.call { throw LLMError.networkError("still down") }
            }
            let state = await breaker.currentState()
            guard case .open = state else {
                Issue.record("expected .open after a failed probe, got \(state)")
                return
            }
            // …and it is not permanently latched: another window admits again.
            try await Task.sleep(for: .milliseconds(40))
            try await breaker.admit()
        }
    }
}
