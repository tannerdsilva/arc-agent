import Foundation

// MARK: - BotReplyBus

/// The per-message reply channel a bot turn publishes into.
///
/// ``SessionHandle/responses`` is a **single-consumer** `AsyncStream`: the
/// session host already runs two loops over it (the HTTP API's chat handler and
/// the streaming path), so a caller that asks a peer a question cannot become a
/// second reader there without stealing values from them — and two concurrent
/// askers would split the answers unpredictably.
///
/// This bus is the correlation path instead. A waiter is keyed by the **id of
/// the message that asked**, so an answer can only ever reach the caller that
/// sent the question it belongs to, and a reply nobody is waiting for is
/// dropped silently (the human-facing path still reads `responses`).
///
/// ## Shape
///
/// Waiters are `AsyncStream` continuations in a dictionary keyed by message id.
/// A published reply resumes the one waiter registered under its id and removes
/// it; a timeout — or a reader that went away — finishes and removes the
/// waiter, so a waiter never outlives the question it belongs to. A stream
/// continuation is used rather than a `CheckedContinuation` because a finished
/// stream is inert: a waiter dropped at the deadline cannot be resumed twice.
actor BotReplyBus {

    /// One waiter per message id.
    ///
    /// Message ids are unique (`BotMessage.id` is a fresh UUID per send), so a
    /// collision means a caller registered the same id twice. The newer
    /// registration replaces the older, which is finished first so it reports
    /// "no reply" instead of hanging forever.
    private var waiters: [String: AsyncStream<String>.Continuation] = [:]

    /// Register a waiter for `id` and return the stream its reply arrives on.
    ///
    /// Registration must happen **before** the message is delivered: a peer
    /// that answers during the delivery call would otherwise publish into
    /// nothing.
    func register(id: String) -> AsyncStream<String> {
        waiters.removeValue(forKey: id)?.finish()
        let (stream, continuation) = AsyncStream<String>.makeStream()
        waiters[id] = continuation
        return stream
    }

    /// Hand `text` to the waiter registered for `id`.
    ///
    /// Returns `false` when nobody is waiting — a human-facing turn, or a
    /// question whose asker already gave up. Such a reply is dropped: the
    /// human path reads ``SessionHandle/responses``, not this bus.
    @discardableResult
    func publish(id: String, text: String) -> Bool {
        guard let waiter = waiters.removeValue(forKey: id) else { return false }
        waiter.yield(text)
        waiter.finish()
        return true
    }

    /// Drop the waiter for `id` without a reply (a timeout, or a reader that
    /// went away). Idempotent, so a timeout and a stream termination racing
    /// each other can both call it.
    func cancel(id: String) {
        waiters.removeValue(forKey: id)?.finish()
    }

    /// The ids currently being waited on.
    ///
    /// Introspection for tests and diagnostics: a caller that times out must
    /// leave nothing behind here.
    var waitingIDs: [String] { Array(waiters.keys) }
}
