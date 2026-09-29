import Foundation
import os

// MARK: - Heartbeat injection (reference `features/heartbeat.md`)

/// Merges a session's heartbeat into its incoming-message stream.
///
/// The heartbeat fires only between turns (never mid-run): a tick producer
/// enqueues the heartbeat prompt alongside user messages; the session's
/// consumer only takes the next message after the current turn completes,
/// so a due heartbeat always lands between turns. Missed ticks coalesce
/// into a single fire (the store re-anchors on fire).
public enum HeartbeatInjector {

    /// Wrap a session's incoming-message stream with heartbeat firing.
    ///
    /// - Parameters:
    ///   - incoming: The adapter's message stream.
    ///   - sessionID: The session owning the heartbeat.
    ///   - store: Durable heartbeat state.
    ///   - pollInterval: How often to check the clock while idle.
    public static func merged(
        over incoming: AsyncStream<IncomingMessage>,
        sessionID: String,
        store: HeartbeatStore,
        pollInterval: Duration = .seconds(5)
    ) -> AsyncStream<IncomingMessage> {
        let (stream, continuation) = AsyncStream<IncomingMessage>.makeStream()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let messageTask = Task {
            var lastChat: ChatTarget? = nil
            for await message in incoming {
                lastChat = message.chat
                continuation.yield(message)
            }
            finished.withLock { $0 = true }
            continuation.finish()
        }
        let tickTask = Task {
            while !Task.isCancelled && !(finished.withLock { $0 }) {
                try? await Task.sleep(for: pollInterval)
                guard !(finished.withLock { $0 }) else { break }
                guard let heartbeat = await store.consumeIfDue(sessionID: sessionID) else {
                    continue
                }
                guard let chat = await store.status(sessionID: sessionID)?.chat,
                      !chat.platform.isEmpty else {
                    continue
                }
                let synthetic = IncomingMessage(
                    id: "heartbeat-\(Int(Date().timeIntervalSince1970))",
                    chat: chat,
                    text: heartbeat.prompt,
                    senderID: "heartbeat",
                    senderName: nil,
                    isReply: false,
                    replyToID: nil,
                    isMention: false,
                    raw: nil
                )
                continuation.yield(synthetic)
            }
        }
        continuation.onTermination = { _ in
            messageTask.cancel()
            tickTask.cancel()
        }
        return stream
    }
}
