import Foundation

// MARK: - Staleness policy + streak tracker (Hermes per-vendor stale-detection
// watchdogs with patience budgets, and `_check_stale_giveup`).

/// Compute per-request patience budgets: request timeout, stream stale
/// timeout, and the reasoning-model floor (Hermes `get_provider_request_timeout`,
/// `get_provider_stale_timeout`, stream stale scaling by token estimate, and
/// `get_reasoning_stale_timeout_floor`).
public enum StalenessPolicy {

    /// Default stream stale timeout in seconds (Hermes
    /// `HERMES_STREAM_STALE_TIMEOUT` default).
    public static let defaultStreamStaleTimeout: Double = 180

    /// Consecutive stale giveups before aborting (Hermes
    /// `HERMES_STREAM_STALE_GIVEUP` default).
    public static let staleGiveupThreshold = 5

    /// Non-stream request timeout default (Hermes provider request timeout).
    public static let defaultRequestTimeout: Double = 120

    /// Token estimates that raise the floor (Hermes: >50K → ≥240s, >100K → ≥300s).
    public static func staleTimeout(base: Double? = nil, estimatedTokens: Int) -> Double {
        var timeout = base ?? defaultStreamStaleTimeout
        if estimatedTokens > 50_000 { timeout = max(timeout, 240) }
        if estimatedTokens > 100_000 { timeout = max(timeout, 300) }
        return timeout
    }

    /// Reasoning stale floor: the minimum patience while a thinking model is
    /// producing its first token (Hermes reasoning_timeouts table, longest
    /// slug match wins).
    public static func reasoningFloor(metadata: ModelMetadata?) -> Double? {
        metadata?.staleTimeoutFloor
    }

    /// Final patience for one stream: configured provider stale timeout
    /// (or default), raised by token estimate and the reasoning floor.
    public static func streamPatience(
        configured: Double? = nil,
        estimatedTokens: Int,
        metadata: ModelMetadata?
    ) -> Double {
        var patience = staleTimeout(base: configured, estimatedTokens: estimatedTokens)
        if let floor = reasoningFloor(metadata: metadata) {
            patience = max(patience, floor)
        }
        return patience
    }
}

/// Tracks consecutive stale-stream giveups; resets on any successful delta.
/// Actor-guarded (First Law).
public actor StaleStreakTracker {
    public private(set) var streak: Int = 0
    private let threshold: Int

    public init(threshold: Int = StalenessPolicy.staleGiveupThreshold) {
        self.threshold = threshold
    }

    /// A stream failed staledown; returns the new streak.
    @discardableResult
    public func recordStale() -> Int {
        streak += 1
        return streak
    }

    /// A stream made progress; reset the streak (Hermes resets on success).
    public func reset() { streak = 0 }

    public var shouldGiveUp: Bool { streak >= threshold }
    public var remainingBeforeGiveUp: Int { max(0, threshold - streak) }
}

/// `LLMError.staleStream` — a stream that went quiet for longer than its
/// patience budget.
public enum StaleStreamError: Error, CustomStringConvertible, Equatable {
    case idleTimeout(seconds: Double)

    public var description: String {
        if case .idleTimeout(let seconds) = self {
            return "Stream stalled after \(seconds)s of no data"
        }
        return "Stream stalled"
    }
}

/// AsyncSequence wrapper enforcing an idle (inter-delta) patience budget on
/// any element stream. A single producer task drains `base` and presents
/// elements on an internal stream; each `next()` on the base is raced against
/// an idle deadline that restarts per element. If the deadline wins, the
/// stream terminates with `StaleStreamError.idleTimeout`. Law-compliant:
/// races via `withThrowingTaskGroup`, one task owns the iterator.
public struct IdleTimeoutStream<Base: AsyncSequence>: AsyncSequence {
    public typealias Element = Base.Element
    let base: Base
    let idleSeconds: Double

    public init(_ base: Base, idleSeconds: Double) {
        self.base = base
        self.idleSeconds = idleSeconds
    }

    public func makeAsyncIterator() -> Iterator {
        let inner = AsyncThrowingStream<Element, Error> { continuation in
            Task {
                var iterator = base.makeAsyncIterator()
                do {
                    while true {
                        let element: Element? = try await Self.wait(
                            timeout: idleSeconds,
                            operation: { try await iterator.next() }
                        )
                        guard let element else { break }
                        continuation.yield(element)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return Iterator(inner: inner.makeAsyncIterator(), stream: inner)
    }

    /// Race `operation` against an idle deadline (Hermes stale watchdog).
    static func wait<T>(timeout: Double, operation: @escaping () async throws -> T?) async throws -> T? {
        if timeout <= 0 { return try await operation() }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw StaleStreamError.idleTimeout(seconds: timeout)
            }
            let first = try await group.next()
            group.cancelAll()
            guard let value = first else {
                throw StaleStreamError.idleTimeout(seconds: timeout)
            }
            return value
        }
    }

    public struct Iterator: AsyncIteratorProtocol {
        var inner: AsyncThrowingStream<Element, Error>.Iterator
        let stream: AsyncThrowingStream<Element, Error>

        public mutating func next() async throws -> Element? {
            try await inner.next()
        }
    }
}
