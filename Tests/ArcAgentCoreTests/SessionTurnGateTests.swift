import Testing
@testable import ArcAgentCore
import Foundation
import Synchronization

// =========================================================================
// MARK: - SessionTurnGate (per-session /v1/chat serialization)

extension ArcCoreTestRoot {
    @Suite("Session turn gate")
    struct SessionTurnGateTests {

        /// The whole point of the gate: concurrent callers for one session
        /// must never overlap — each operation runs alone in the slot.
        @Test("operations for one session serialize, never overlap")
        func serializesAccess() async throws {
            let gate = SessionTurnGate(maxWaiters: 16)
            let tracker = OverlapTracker()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<6 {
                    group.addTask {
                        try await gate.withTurn(sessionID: "s1") {
                            await tracker.enter(index)
                            try await Task.sleep(nanoseconds: 10_000_000)
                            await tracker.exit()
                        }
                    }
                }
                try await group.waitForAll()
            }

            let maxConcurrency = await tracker.maxInFlight
            #expect(maxConcurrency == 1, "expected strictly serial turns, saw max in-flight \(maxConcurrency)")
        }

        /// Different sessions are independent: two slots can be held at once.
        @Test("different sessions gate independently")
        func independentSessions() async throws {
            let gate = SessionTurnGate(maxWaiters: 16)
            let tracker = OverlapTracker()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await gate.withTurn(sessionID: "a") { await tracker.enter(0); try await Task.sleep(nanoseconds: 50_000_000); await tracker.exit() } }
                group.addTask { try await gate.withTurn(sessionID: "b") { await tracker.enter(1); try await Task.sleep(nanoseconds: 50_000_000); await tracker.exit() } }
                try await group.waitForAll()
            }

            let maxConcurrency = await tracker.maxInFlight
            #expect(maxConcurrency == 2, "expected two independent sessions to run concurrently, saw \(maxConcurrency)")
        }

        /// Beyond `maxWaiters`, callers fail fast with `.queueFull` instead of
        /// hanging — the HTTP layer turns that into 429.
        @Test("queue overflows fail fast with queueFull")
        func queueOverflowFailsFast() async throws {
            let gate = SessionTurnGate(maxWaiters: 1)

            // Hold the slot.
            try await gate.acquire(sessionID: "s")

            // First waiter queues (suspends). Wait until it is observable.
            let waiter = Task { try await gate.acquire(sessionID: "s") }
            for _ in 0..<100 where await gate.waiterCount(sessionID: "s") == 0 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let queued = await gate.waiterCount(sessionID: "s")
            #expect(queued == 1, "expected one queued waiter, saw \(queued)")

            // Queue is full: this caller must fail fast, not suspend.
            await #expect(throws: SessionTurnGateError.queueFull(sessionID: "s")) {
                try await gate.acquire(sessionID: "s")
            }

            // Drain: release hands off to the queued waiter, which completes.
            await gate.release(sessionID: "s")
            try await waiter.value // must not throw

            let stillHeld = await gate.isHeld(sessionID: "s")
            #expect(stillHeld, "handoff must leave the slot held by the resumed waiter")
            await gate.release(sessionID: "s")
        }

        /// A throwing operation releases the slot — errors never strand it.
        @Test("withTurn releases the slot when the operation throws")
        func releasesOnThrow() async throws {
            struct Boom: Error {}
            let gate = SessionTurnGate()

            await #expect(throws: Boom.self) {
                try await gate.withTurn(sessionID: "s") { () throws -> Int in throw Boom() }
            }
            let held = await gate.isHeld(sessionID: "s")
            #expect(!held, "slot must be released after a throwing operation")

            // And the next caller can take it immediately.
            let value = try await gate.withTurn(sessionID: "s") { 42 }
            #expect(value == 42)
        }

        /// A cancelled waiter neither hangs nor steals the handoff: the slot
        /// ends up with the surviving caller.
        @Test("cancelled waiter unwinds without stranding the slot")
        func cancelledWaiterUnwinds() async throws {
            let gate = SessionTurnGate(maxWaiters: 4)

            try await gate.acquire(sessionID: "s")

            let waiter = Task { try await gate.acquire(sessionID: "s") }
            for _ in 0..<100 where await gate.waiterCount(sessionID: "s") == 0 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            waiter.cancel()
            await #expect(throws: (any Error).self) { try await waiter.value }

            // Slot is still held by the original acquirer; release hands to
            // nobody and the next caller proceeds immediately.
            await gate.release(sessionID: "s")
            let value = try await gate.withTurn(sessionID: "s") { 7 }
            #expect(value == 7)
        }
    }
}

/// Shared overlap probe for the serialization tests. `Mutex` (Synchronization)
/// instead of a hand-rolled lock — First Law-clean, and trivially Sendable.
private final class OverlapTracker: Sendable {
    private let state = Mutex<(inFlight: Int, max: Int)>((0, 0))

    func enter(_ index: Int) {
        state.withLock { state in
            state.inFlight += 1
            state.max = max(state.max, state.inFlight)
        }
    }

    func exit() {
        state.withLock { state in
            state.inFlight -= 1
        }
    }

    var maxInFlight: Int {
        state.withLock { $0.max }
    }
}
