import Foundation

// MARK: - Staleness policy + streak tracker (reference per-vendor stale-detection
// watchdogs with patience budgets, and `_check_stale_giveup`).

/// Compute per-request patience budgets: request timeout, stream stale
/// timeout, and the reasoning-model floor (reference `get_provider_request_timeout`,
/// `get_provider_stale_timeout`, stream stale scaling by token estimate, and
/// `get_reasoning_stale_timeout_floor`).
public enum StalenessPolicy {

    /// Default stream stale timeout in seconds (upstream
    /// stream-stale default).
    public static let defaultStreamStaleTimeout: Double = 180

    /// Consecutive stale giveups before aborting (upstream
    /// stale-giveup default).
    public static let staleGiveupThreshold = 5

    /// Non-stream request timeout default (reference provider request timeout).
    public static let defaultRequestTimeout: Double = 120

    /// Token estimates that raise the floor (reference: >50K → ≥240s, >100K → ≥300s).
    public static func staleTimeout(base: Double? = nil, estimatedTokens: Int) -> Double {
        var timeout = base ?? defaultStreamStaleTimeout
        if estimatedTokens > 50_000 { timeout = max(timeout, 240) }
        if estimatedTokens > 100_000 { timeout = max(timeout, 300) }
        return timeout
    }

    /// Reasoning stale floor: the minimum patience while a thinking model is
    /// producing its first token (reference reasoning_timeouts table, longest
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

    /// A stream made progress; reset the streak (reference resets on success).
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

/// `IdleTimeoutStream`'s wall-clock companion: the *total* lifetime budget.
/// Unlike ``StaleStreamError`` (which measures silence between deltas), this
/// fires even when the provider is steadily trickling data, bounding a turn
/// that would otherwise run until one response completes.
public struct StreamTotalTimeoutError: Error, CustomStringConvertible, Equatable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public var description: String {
        "Stream exceeded its \(seconds)s total duration budget"
    }
}

/// Single-consumer holder for a non-Sendable iterator: the idle-race hands
/// the iterator to exactly one task (the waiter), which is the only mutation
/// site, and the holder is safely closed over by the `@Sendable` race
/// closures. Access is governed by the task-group lifetime.
private final class IteratorBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// AsyncSequence wrapper enforcing an idle (inter-delta) patience budget on
/// any element stream, plus an optional wall-clock ``totalSeconds`` budget. A
/// single producer task drains `base` and presents elements on an internal
/// stream; each `next()` on the base is raced against a deadline that
/// restarts per element (idle budget) and bounded by the remaining total
/// budget. If a deadline wins, the stream terminates with
/// `StaleStreamError.idleTimeout` or ``StreamTotalTimeoutError``. Law-compliant:
/// races via `withThrowingTaskGroup`, one task owns the iterator.
public struct IdleTimeoutStream<Base: AsyncSequence>: AsyncSequence where Base: Sendable, Base.Element: Sendable {
    public typealias Element = Base.Element
    let base: Base
    let idleSeconds: Double
    let totalSeconds: Double?

    public init(_ base: Base, idleSeconds: Double, totalSeconds: Double? = nil) {
        self.base = base
        self.idleSeconds = idleSeconds
        self.totalSeconds = totalSeconds
    }

    public func makeAsyncIterator() -> Iterator {
        let inner = AsyncThrowingStream<Element, Error> { continuation in
            let box = IteratorBox(base.makeAsyncIterator())
            let idle = idleSeconds
            let total = totalSeconds
            let start = Date()
            Task {
                do {
                    while true {
                        var deadline = idle
                        var useTotalKind = false
                        if let total {
                            let elapsed = Date().timeIntervalSince(start)
                            let remaining = total - elapsed
                            if remaining <= 0 {
                                throw StreamTotalTimeoutError(seconds: total)
                            }
                            deadline = Swift.min(idle, remaining)
                            useTotalKind = remaining <= idle
                        }
                        let element: Element? = try await Self.wait(
                            timeout: deadline,
                            kind: useTotalKind ? .total : .idle,
                            operation: { try await box.value.next() }
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

    /// What a deadline represents — determines which error a timed-out wait
    /// raises (``StaleStreamError`` for silence, ``StreamTotalTimeoutError``
    /// for the wall-clock budget).
    enum DeadlineKind {
        case idle
        case total
    }

    /// Race `operation` against a deadline (reference stale watchdog).
    static func wait<T: Sendable>(
        timeout: Double,
        kind: DeadlineKind = .idle,
        operation: @escaping @Sendable () async throws -> T?
    ) async throws -> T? {
        if timeout <= 0 { return try await operation() }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                switch kind {
                case .idle:
                    throw StaleStreamError.idleTimeout(seconds: timeout)
                case .total:
                    throw StreamTotalTimeoutError(seconds: timeout)
                }
            }
            let first = try await group.next()
            group.cancelAll()
            guard let value = first else {
                switch kind {
                case .idle:
                    throw StaleStreamError.idleTimeout(seconds: timeout)
                case .total:
                    throw StreamTotalTimeoutError(seconds: timeout)
                }
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
