import Foundation
import ServiceLifecycle

/// A platform adapter connects the gateway to a messaging platform.
///
/// Each platform adapter is a ``Service`` managed by the gateway's
/// ``ServiceGroup``. It produces an ``AsyncStream`` of incoming messages
/// and provides a method to send outgoing messages back to the platform.
///
/// - Note: The `start()`/`stop()` lifecycle is managed by the
///   ``Service`` protocol's `run()` method. Adapters should run their
///   polling or websocket loop in `run()` and clean up on cancellation.
public protocol PlatformAdapter: Service {
    /// Human-readable name for this adapter (e.g. "telegram", "discord").
    var name: String { get }

    /// Send a message to a chat target on this platform.
    func send(message: OutgoingMessage, to: ChatTarget) async throws

    /// An async stream of incoming messages from this platform.
    ///
    /// The gateway reads from this stream to dispatch messages to agent
    /// sessions. The stream should produce messages as they arrive and
    /// terminate when the adapter is cancelled.
    var incomingMessages: AsyncStream<IncomingMessage> { get }
}
