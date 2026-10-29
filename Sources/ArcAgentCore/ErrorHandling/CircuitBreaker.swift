import Foundation

/// Tracks failure counts for a resource and prevents calls when the threshold
/// is exceeded.
///
/// ## States
///
/// ```
/// ┌──────────┐   failure threshold    ┌──────────┐   timeout elapses   ┌──────────┐
/// │  CLOSED  │ ──────────────────────→│   OPEN   │ ───────────────────→│ HALF_OPEN │
/// │ (normal) │                        │ (blocked)│                     │ (probing)│
/// └──────────┘                        └──────────┘                     └──────────┘
///      ↑                                                                    │
///      └────────────────────── success ─────────────────────────────────────┘
/// ```
///
/// ## Usage
///
/// ```swift
/// let breaker = CircuitBreaker(label: "primary-llm", threshold: 5, resetTimeout: 30)
///
/// try await breaker.call {
///     try await llm.complete(messages: messages)
/// }
/// ```
public actor CircuitBreaker {
    public enum State: Sendable, CustomStringConvertible {
        /// Normal operation — calls pass through.
        case closed
        /// Threshold exceeded — calls are rejected immediately.
        case open(resetAt: Date)
        /// Probing — calls are admitted again so recovery can be observed; the
        /// first failure reopens the circuit for another window.
        case halfOpen

        public var description: String {
            switch self {
            case .closed: return "closed"
            case .open(let resetAt): return "open (reset at \(resetAt))"
            case .halfOpen: return "half-open"
            }
        }
    }

    /// A human-readable label for this breaker.
    public let label: String
    /// Number of consecutive failures before opening.
    public let threshold: Int
    /// Seconds to wait before transitioning to half-open.
    public let resetTimeout: TimeInterval

    private var state: State = .closed
    private var failureCount: Int = 0
    private var lastFailure: Date?
    private var lastFailureReason: String?

    public init(label: String, threshold: Int = 5, resetTimeout: TimeInterval = 30) {
        self.label = label
        self.threshold = threshold
        self.resetTimeout = resetTimeout
    }

    // MARK: - Public API

    /// Execute an operation through the circuit breaker.
    /// - Parameter operation: The async operation to execute.
    /// - Returns: The operation's result.
    /// - Throws: ``CircuitBreakerError/open(label:resetAt:lastFailureReason:)`` if the circuit is open.
    public func call<T>(operation: () async throws -> T) async throws -> T {
        try admit()

        do {
            let result = try await operation()
            onSuccess()
            return result
        } catch {
            onFailure(error)
            throw error
        }
    }

    /// Ask whether a call may proceed now.
    ///
    /// This is the **only** place the ``State/open(resetAt:)`` → ``State/halfOpen``
    /// transition happens: `currentState()` is a pure query, so a caller that
    /// gates on it alone leaves a tripped breaker rejecting every call for the
    /// life of the process — the reset window elapses and nothing ever notices.
    /// Admission is therefore an action, not a read.
    ///
    /// - Throws: ``CircuitBreakerError/open(label:resetAt:lastFailureReason:)``
    ///   while the reset window is still running.
    public func admit() throws {
        try checkState()
    }

    /// Record a successful call: a probe in `half-open` closes the circuit, and
    /// a success in `closed` clears the consecutive-failure count.
    public func recordSuccess() {
        onSuccess()
    }

    /// The current state of the circuit breaker.
    public func currentState() -> State { state }

    /// Reset the circuit breaker to closed state.
    public func reset() {
        state = .closed
        failureCount = 0
        lastFailure = nil
        lastFailureReason = nil
    }

    /// Record a failure, incrementing the failure count.
    /// If the threshold is reached, the circuit opens.
    public func recordFailure(_ error: Error) {
        failureCount += 1
        lastFailure = Date()
        lastFailureReason = error.localizedDescription

        if failureCount >= threshold {
            state = .open(resetAt: Date().addingTimeInterval(resetTimeout))
        }
    }

    // MARK: - Private

    private func checkState() throws {
        switch state {
        case .closed:
            return
        case .open(let resetAt):
            if Date() >= resetAt {
                // The window elapsed: probe the endpoint instead of rejecting
                // it forever. This transition is what `admit()` exists for.
                state = .halfOpen
                return
            }
            throw CircuitBreakerError.open(
                label: label,
                resetAt: resetAt,
                lastFailureReason: lastFailureReason ?? "Unknown"
            )
        case .halfOpen:
            return
        }
    }

    private func onSuccess() {
        switch state {
        case .halfOpen:
            // Success in half-open means we've recovered
            state = .closed
            failureCount = 0
            lastFailure = nil
            lastFailureReason = nil
        case .closed:
            // Success in closed — reset failure count on consecutive successes
            failureCount = 0
        case .open:
            break
        }
    }

    private func onFailure(_ error: Error) {
        failureCount += 1
        lastFailure = Date()
        lastFailureReason = error.localizedDescription

        if failureCount >= threshold {
            state = .open(resetAt: Date().addingTimeInterval(resetTimeout))
        }
    }
}

/// Errors thrown by ``CircuitBreaker``.
public enum CircuitBreakerError: Error, Sendable, CustomStringConvertible {
    /// The circuit is open — calls are being rejected.
    case open(label: String, resetAt: Date, lastFailureReason: String)

    public var description: String {
        switch self {
        case .open(let label, let resetAt, let reason):
            return "Circuit breaker '\(label)' is open until \(resetAt). Last failure: \(reason)"
        }
    }
}
