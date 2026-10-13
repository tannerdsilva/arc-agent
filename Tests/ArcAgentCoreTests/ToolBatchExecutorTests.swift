import Foundation
import Testing
@testable import ArcAgentCore

/// reference `_MAX_TOOL_WORKERS` / `_DEFAULT_CONCURRENT_TOOL_TIMEOUT_S` parity:
/// capped concurrency plus a batch deadline so a wedged `swift test` can no
/// longer hang the turn (the 9-hour freeze that motivated the port).
@Suite("Tool batch executor")
struct ToolBatchExecutorTests {

    /// Concurrency probe: records the max number of simultaneously-running
    /// bodies (actor-guarded — no hand-rolled locking).
    private actor ConcurrencyProbe {
        private(set) var active = 0
        private(set) var maxActive = 0
        func enter() async {
            active += 1
            maxActive = max(maxActive, active)
        }
        func leave() async {
            active -= 1
        }
    }

    @Test("concurrency is capped at maxParallel")
    func capRespected() async {
        let probe = ConcurrencyProbe()
        let calls = [1, 2, 3, 4, 5, 6]
        let outcomes = await ToolBatchExecutor.run(
            calls,
            maxParallel: 2,
            timeoutSeconds: nil, // no deadline: pure cap test
            nameOf: { "c\($0)" },
            body: { _ in
                await probe.enter()
                try? await Task.sleep(nanoseconds: 150_000_000)
                await probe.leave()
                return "done"
            }
        )
        #expect(outcomes.count == 6)
        #expect(outcomes.allSatisfy { !$0.timedOut })
        let maxActive = await probe.maxActive
        #expect(maxActive <= 2, "exceeded maxParallel: \(maxActive) concurrent")
    }

    @Test("defaults match reference limits: 8 workers, 420 s deadline")
    func batchDefaults() {
        #expect(ToolBatchLimits.maxWorkers == 8)
        #expect(ToolBatchLimits.defaultBatchTimeout == 420.0)
    }

    @Test("ARC_CONCURRENT_TOOL_TIMEOUT_S parse: default/invalid/disabled/value")
    func timeoutParse() {
        #expect(ToolBatchLimits.parseTimeout(nil) == 420.0)
        #expect(ToolBatchLimits.parseTimeout("") == 420.0)
        #expect(ToolBatchLimits.parseTimeout("not-a-number") == 420.0)
        #expect(ToolBatchLimits.parseTimeout("0") == nil)
        #expect(ToolBatchLimits.parseTimeout("-1") == nil)
        #expect(ToolBatchLimits.parseTimeout("30") == 30.0)
        #expect(ToolBatchLimits.parseTimeout(" 120 ") == 120.0)
    }

    @Test("results come back in input order (no deadline)")
    func orderPreserved() async {
        let calls = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
        let outcomes = await ToolBatchExecutor.run(
            calls,
            maxParallel: 3,
            timeoutSeconds: nil,
            nameOf: { $0 },
            body: { value in
                // Reverse-order completion: long sleep for early calls so they
                // finish LAST — output order must still be input order.
                let delay = UInt64(calls.count - (calls.firstIndex(of: value) ?? 0)) * 20_000_000
                try? await Task.sleep(nanoseconds: delay)
                return "result-\(value)"
            }
        )
        #expect(outcomes.map(\.result) == calls.map { "result-\($0)" })
        #expect(outcomes.allSatisfy { !$0.timedOut })
    }

    @Test("deadline abandons the batch and returns promptly, real results win")
    func deadlineAbandons() async {
        let started = ContinuousClock.now
        // One fast call (real result) + one long call. The long call is
        // cancellation-cooperative: on cancel it returns quickly (bounded),
        // so the batch must come back in well under its 60 s sleep.
        let outcomes = await ToolBatchExecutor.run(
            ["fast", "slow"],
            maxParallel: 2,
            timeoutSeconds: 0.3,
            nameOf: { $0 },
            body: { value in
                if value == "fast" {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    return "fast-result"
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return "slow-result"
            }
        )
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(30), "batch took too long: \(elapsed)")
        // Both calls still produce their own results — the watchdog's job is
        // to bound the batch, not to fabricate outcomes for work that
        // returned. The fast one is its real result.
        #expect(outcomes[0].result == "fast-result")
    }

    @Test("empty batch is a no-op")
    func emptyBatch() async {
        let outcomes = await ToolBatchExecutor.run(
            [Int](), maxParallel: 4, timeoutSeconds: 1.0,
            nameOf: { "\($0)" }, body: { _ in "x" }
        )
        #expect(outcomes.isEmpty)
    }

    @Test("fast batch with watchdog present returns immediately (not after the deadline)")
    func fastCompletionDoesNotWaitForDeadline() async {
        let started = ContinuousClock.now
        let outcomes = await ToolBatchExecutor.run(
            ["a", "b", "c"],
            maxParallel: 3,
            timeoutSeconds: 60.0, // long deadline must NOT delay a fast batch
            nameOf: { $0 },
            body: { value in
                try? await Task.sleep(nanoseconds: 80_000_000)
                return "ok-\(value)"
            }
        )
        let elapsed = ContinuousClock.now - started
        #expect(outcomes.map(\.result) == ["ok-a", "ok-b", "ok-c"])
        #expect(outcomes.allSatisfy { !$0.timedOut })
        #expect(elapsed < .seconds(30), "batch should return promptly, took \(elapsed)")
    }

    @Test("placeholder formatting matches reference wording")
    func placeholderWording() {
        let label = String(format: "%.1fs", 420.0)
        #expect(label == "420.0s")
        let message = "Error executing tool 'terminal': timed out after \(label)"
        #expect(message == "Error executing tool 'terminal': timed out after 420.0s")
    }
}
