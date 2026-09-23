import Foundation

/// Hermes `agent/tool_executor.py` concurrent-batch watchdog parity.
///
/// Hermes runs up to ``ToolBatchLimits/maxWorkers`` tool calls concurrently
/// with a per-batch deadline (`_DEFAULT_CONCURRENT_TOOL_TIMEOUT_S` = 420 s,
/// env-overridable). When the deadline fires the batch is **abandoned**:
/// still-running calls are reported to the model as
/// `"Error executing tool '<name>': timed out after 420.0s"` and the turn
/// continues — instead of hanging for hours on a wedged `swift test` (the
/// freeze that motivated this port).
///
/// Deliberate differences from Hermes' thread-pool implementation:
///
/// 1. **No start-order gate.** Hermes needs `_begin_in_order` because one
///    worker's wedged dispatch parks a pooled *thread*; Swift `TaskGroup`
///    children don't share a pool, so a wedged dispatch cannot starve
///    siblings. The gate's purpose (anti-starvation) is inherent here.
/// 2. **Cooperative cancellation.** On abandon we `cancelAll()` and drain;
///    every arc tool is bounded (terminal/subprocess have hard timeouts,
///    file ops are quick), so cancelled children finish promptly. A child
///    that ignored cancellation would still hold the group scope — same
///    tradeoff Hermes accepts (its wedged threads are left detached).
///
/// Results are returned in input order; a real result that lands after the
/// deadline wins over the timeout placeholder (Hermes does the same).
public enum ToolBatchLimits {
    /// Hermes `_MAX_TOOL_WORKERS`.
    public static let maxWorkers = 8
    /// Hermes `_DEFAULT_CONCURRENT_TOOL_TIMEOUT_S` — kept above the stock
    /// web_extract-style timeout so the guard never preempts slow-but-valid
    /// work.
    public static let defaultBatchTimeout: Double = 420.0
    /// Env override (Hermes `HERMES_CONCURRENT_TOOL_TIMEOUT_S` parity, arc
    /// naming): `ARC_CONCURRENT_TOOL_TIMEOUT_S`. Empty → default, `≤0` →
    /// deadline disabled.
    public static func batchTimeoutFromEnv(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        parseTimeout(env["ARC_CONCURRENT_TOOL_TIMEOUT_S"])
    }
    /// Testable parse: `nil`/empty → default; invalid → default (with a
    /// warning in spirit); `≤0` → `nil` (disabled).
    public static func parseTimeout(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return defaultBatchTimeout
        }
        guard let value = Double(raw) else {
            return defaultBatchTimeout
        }
        return value <= 0 ? nil : value
    }
}

public struct ToolBatchOutcome: Sendable {
    public let result: String
    public let timedOut: Bool
}

public enum ToolBatchExecutor {

    private struct BatchItem: Sendable {
        let index: Int
        let result: String
        let name: String
    }

    /// Run `calls` concurrently, capped at `maxParallel`, with a batch
    /// deadline. Returns one outcome per input call, in input order.
    public static func run<T: Sendable>(
        _ calls: [T],
        maxParallel: Int = ToolBatchLimits.maxWorkers,
        timeoutSeconds: Double? = ToolBatchLimits.batchTimeoutFromEnv(),
        nameOf: @escaping @Sendable (T) -> String,
        body: @escaping @Sendable (T) async -> String
    ) async -> [ToolBatchOutcome] {
        let count = calls.count
        guard count > 0 else { return [] }
        let cap = max(1, min(maxParallel, count))

        var items: [BatchItem] = []
        var abandoned = false

        await withTaskGroup(of: BatchItem.self) { group in
            var next = 0
            var inFlight = 0

            func startNext() {
                guard next < count else { return }
                let index = next
                next += 1
                inFlight += 1
                group.addTask {
                    let result = await body(calls[index])
                    return BatchItem(index: index, result: result, name: nameOf(calls[index]))
                }
            }

            // Windowed dispatch: at most `cap` children in flight (Hermes
            // `_MAX_TOOL_WORKERS`); a completed child refills the window.
            for _ in 0..<cap {
                startNext()
            }

            // Deadline watchdog: a sibling task that returns the sentinel
            // (`index == -1`) once the batch deadline passes.
            if let timeoutSeconds {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return BatchItem(index: -1, result: "", name: "")
                }
            }

            while let item = await group.next() {
                if item.index == -1 {
                    // Batch deadline fired: abandon. Cancel in-flight work and
                    // keep draining — any child that still produces a real
                    // result (it was bounded, just late) is preferred over a
                    // fabricated timeout (Hermes-parity).
                    abandoned = true
                    group.cancelAll()
                    continue
                }
                if !abandoned {
                    inFlight -= 1
                    startNext()
                }
                items.append(item)
                // All real calls collected: cancel the deadline watchdog so
                // `group.next()` doesn't block on its full sleep — a batch
                // that finishes in 2 s must return in 2 s, not 420 s (the
                // watchdog only exists to bound unfinished work).
                if next >= count && items.count == count {
                    group.cancelAll()
                }
            }
        }

        // Synthesize the outcome array in input order. Real results win;
        // abandoned slots get Hermes' exact timeout message.
        var outcomes = [ToolBatchOutcome?](repeating: nil, count: count)
        for item in items where item.index >= 0 && item.index < count {
            outcomes[item.index] = ToolBatchOutcome(result: item.result, timedOut: false)
        }
        let timeoutLabel = timeoutSeconds.map { String(format: "%.1fs", $0) } ?? "the configured timeout"
        return outcomes.enumerated().map { index, outcome in
            if let outcome {
                return outcome
            }
            let name = nameOf(calls[index])
            return ToolBatchOutcome(
                result: "Error executing tool '\(name)': timed out after \(timeoutLabel)",
                timedOut: true
            )
        }
    }
}
