import Foundation

/// An error surfaced by ``SessionTurnGate``.
public enum SessionTurnGateError: Error, Sendable, Equatable {
    /// The per-session wait queue is full — the caller should back off
    /// (mapped to HTTP 429 by the REST surface).
    case queueFull(sessionID: String)

    /// Convenience for error mapping in the HTTP layer.
    public var isQueueFull: Bool {
        if case .queueFull = self { return true }
        return false
    }
}

/// A bounded, single-flight per-session turn gate for the REST API surface.
///
/// Serializes `POST /v1/chat` turns **per session**: at most one in-flight
/// turn holds a session's slot, up to `maxWaiters` additional requests for
/// that session suspend in a FIFO queue, and further callers fail fast with
/// ``SessionTurnGateError/queueFull``. Different sessions never block each
/// other — each session has its own slot.
///
/// This closes the stolen-reply race in the `/v1/chat` path: the session's
/// `responses` stream is a unicast `AsyncStream` — every yielded value is
/// delivered to exactly one waiter. With a single waiter per session at a
/// time, each reply is consumed by the request that produced it.
///
/// First Law: actor-isolated, no locks; waiting is expressed as a checked
/// continuation inside the actor's serial executor.
public actor SessionTurnGate {

    private struct Waiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Sessions that currently hold a turn slot (one in-flight turn each).
    private var holders: Set<String> = []
    /// FIFO wait queues, keyed by the session the caller wants a slot for.
    private var waiters: [String: [Waiter]] = [:]
    private let maxWaiters: Int

    /// - Parameter maxWaiters: How many requests may queue behind an
    ///   in-flight turn for the same session before failing fast (429).
    public init(maxWaiters: Int = 8) {
        self.maxWaiters = maxWaiters
    }

    /// Run `operation` while holding the turn slot for `sessionID`.
    /// The slot is released on every exit path, including throws and
    /// task cancellation unwinding through the acquire.
    public func withTurn<T: Sendable>(
        sessionID: String,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(sessionID: sessionID)
        do {
            let value = try await operation()
            release(sessionID: sessionID)
            return value
        } catch {
            release(sessionID: sessionID)
            throw error
        }
    }

    /// Acquire the turn slot for `sessionID`, suspending while another turn
    /// holds it. Throws ``SessionTurnGateError/queueFull`` when the wait
    /// queue for the session is already at capacity.
    public func acquire(sessionID: String) async throws {
        if !holders.contains(sessionID) {
            holders.insert(sessionID)
            return
        }
        var queue = waiters[sessionID] ?? []
        guard queue.count < maxWaiters else {
            throw SessionTurnGateError.queueFull(sessionID: sessionID)
        }
        let waiterID = UUID()
        // If the calling task is cancelled while suspended, remove the
        // waiter and resume it with a CancellationError. The removal is
        // guarded: if `release` already handed the slot off, the waiter is
        // no longer in the queue and the cancellation is a no-op.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.append(Waiter(id: waiterID, continuation: continuation))
                waiters[sessionID] = queue
            }
        } onCancel: {
            Task { await self.cancelWaiter(sessionID: sessionID, id: waiterID) }
        }
        // Resumed: either the slot was handed off, or the wait was
        // cancelled (the continuation threw CancellationError, so we never
        // reach here). If the caller's task was cancelled between handoff
        // and here, give the slot back so it is not leaked.
        if Task.isCancelled {
            release(sessionID: sessionID)
        }
    }

    /// Release the turn slot for `sessionID`, handing it to the next
    /// queued waiter if there is one (the slot stays held by the session —
    /// the resumed waiter *is* the new holder).
    public func release(sessionID: String) {
        guard holders.contains(sessionID) else { return }
        if var queue = waiters[sessionID], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[sessionID] = queue.isEmpty ? nil : queue
            holders.insert(sessionID)  // handed off to the resumed waiter
            next.continuation.resume(returning: ())
        } else {
            waiters[sessionID] = nil
            holders.remove(sessionID)
        }
    }

    /// Number of requests currently waiting for a slot on `sessionID`.
    public func waiterCount(sessionID: String) -> Int {
        waiters[sessionID]?.count ?? 0
    }

    /// Whether `sessionID` currently has an in-flight turn.
    public func isHeld(sessionID: String) -> Bool {
        holders.contains(sessionID)
    }

    private func cancelWaiter(sessionID: String, id: UUID) {
        guard var queue = waiters[sessionID],
              let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[sessionID] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }
}
