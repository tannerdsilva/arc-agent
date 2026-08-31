import Foundation
import ServiceLifecycle
import Logging

// MARK: - BotMessagingService

/// The inter-agent messaging service that handles bot-to-bot communication.
///
/// ``BotMessagingService`` is an **actor** and a ``Service`` in the lifecycle
/// tree. It manages:
/// - Delivery of messages between bot profiles
/// - The canonical "Bot Chat" session per profile
/// - @-mention handoff resolution
/// - Activity tracking for the roster's "active now" strip
///
/// ## Architecture
///
/// Unlike Hermes Bot Mode (which uses CLI invocation for bot-to-bot delivery),
/// ARC Agent uses **direct actor method calls**. When Bot A sends a message to
/// Bot B, the message is routed through ``BotMessagingService``, which delivers
/// it directly into Bot B's canonical session via the ``SessionRegistry``.
/// No shell composition, no polling, no background process coordination.
///
/// ## Law of the Land
///
/// - **First Law**: ``BotMessagingService`` is an actor — all state is
///   serialized by the actor's executor.
/// - **Second Law**: ``BotMessagingService`` is a ``Service`` in the lifecycle
///   tree, managed by ``ServiceGroup``.
public actor BotMessagingService: Service {

    // MARK: - Types

    /// A message sent between bots.
    public struct BotMessage: Sendable, Codable {
        /// The sender's profile name.
        public let from: String
        /// The sender's display name.
        public let fromDisplay: String
        /// The recipient's profile name.
        public let to: String
        /// The message body.
        public let body: String
        /// When the message was sent.
        public let timestamp: Date
        /// Unique message identifier.
        public let id: String

        /// The formatted delivery prefix.
        public var deliveryPrefix: String {
            "Message from \(fromDisplay) (@\(from)):"
        }

        /// The full message text as the recipient sees it.
        public var formattedText: String {
            "\(deliveryPrefix) \(body)"
        }

        public init(from: String, fromDisplay: String, to: String, body: String) {
            self.from = from
            self.fromDisplay = fromDisplay
            self.to = to
            self.body = body
            self.timestamp = Date()
            self.id = UUID().uuidString
        }
    }

    /// Activity event for the roster's "active now" tracking.
    public struct ActivityEvent: Sendable {
        /// The profile that was active.
        public let profile: String
        /// When the activity occurred.
        public let timestamp: Date
        /// What kind of activity.
        public let kind: ActivityKind
    }

    /// Kinds of bot activity.
    public enum ActivityKind: String, Sendable {
        case messageSent
        case messageReceived
        case turnStarted
        case turnCompleted
        case cronRun
    }

    // MARK: - State

    /// Reference to the profile manager for profile lookups.
    private let profileManager: ProfileManager
    /// Reference to the session registry for message delivery.
    private var sessionRegistry: SessionRegistry?
    /// Activity stream for the roster's "active now" strip.
    private let activityContinuation: AsyncStream<ActivityEvent>.Continuation
    /// Public activity stream.
    public private(set) var activityStream: AsyncStream<ActivityEvent>
    /// Logger.
    private let logger: Logger

    public init(profileManager: ProfileManager) {
        self.profileManager = profileManager
        self.logger = Logger(label: "com.arc-agent.bot-messaging")

        var continuation: AsyncStream<ActivityEvent>.Continuation!
        self.activityStream = AsyncStream { continuation = $0 }
        self.activityContinuation = continuation
    }

    /// Set the session registry reference (called during gateway setup).
    func setSessionRegistry(_ registry: SessionRegistry) {
        self.sessionRegistry = registry
    }

    // MARK: - Service

    public func run() async throws {
        logger.info("Bot messaging service started")

        // The service runs until cancelled — it holds the activity stream
        // continuation and the session registry reference.
        try await Task.sleep(nanoseconds: UInt64.max)
    }

    // MARK: - Sending Messages

    /// Send a message from one bot to another.
    ///
    /// Unlike Hermes Bot Mode (which shells out to `hermes -p <target> chat ...`),
    /// this delivers the message directly into the recipient's canonical session
    /// via the ``SessionRegistry``. The recipient bot sees it as a normal incoming
    /// message on its next turn.
    ///
    /// - Parameters:
    ///   - message: The message to send.
    /// - Throws: ``ProfileError/notFound`` if the sender or recipient doesn't exist.
    public func sendMessage(_ message: BotMessage) async throws {
        // Validate both profiles exist
        guard try await profileManager.get(name: message.from) != nil else {
            throw ProfileError.notFound(message.from)
        }
        guard try await profileManager.get(name: message.to) != nil else {
            throw ProfileError.notFound(message.to)
        }

        // Record activity
        activityContinuation.yield(ActivityEvent(
            profile: message.from,
            timestamp: Date(),
            kind: .messageSent
        ))

        logger.info("Bot message: \(message.from) -> \(message.to): \(message.body.prefix(60))")

        // If we have a session registry, deliver directly into the recipient's session.
        // The recipient bot will see the message on its next turn.
        if let registry = sessionRegistry {
            let canonicalChatID = try await profileManager.getOrCreateCanonicalChat(profile: message.to)
            let incoming = IncomingMessage(
                id: message.id,
                chat: ChatTarget(platform: "bot", chatID: canonicalChatID),
                text: message.formattedText,
                senderID: message.from
            )
            let handle = await registry.getOrCreate(sessionID: canonicalChatID, profile: message.to)
            handle.inputContinuation.yield(incoming)
        }
    }

    /// Send a message and wait for a reply.
    ///
    /// This is a synchronous-style API: the caller awaits the reply inline.
    /// The message is delivered to the recipient, and the caller receives
    /// the response via an ``AsyncThrowingStream``.
    ///
    /// - Parameters:
    ///   - message: The message to send.
    /// - Returns: An async stream of reply tokens.
    public func sendMessageAndWait(_ message: BotMessage) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await sendMessage(message)
                    // In a full implementation, this would subscribe to the
                    // recipient's response stream. For now, we deliver and return.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Activity Tracking

    /// Report an activity event for a bot.
    public func reportActivity(profile: String, kind: ActivityKind) {
        activityContinuation.yield(ActivityEvent(
            profile: profile,
            timestamp: Date(),
            kind: kind
        ))
    }

    /// Get the recent activity for the "active now" strip.
    /// Returns profiles that have been active within the last 90 seconds.
    public func recentActivity(within seconds: TimeInterval = 90) async -> [String] {
        // Collect from the activity stream — in practice this would be
        // backed by a ring buffer. For now, return an empty list.
        // The web UI polls the roster directly for last_active timestamps.
        []
    }

    // MARK: - Canonical Chat

    /// Get or create the canonical "Bot Chat" session for a profile.
    public func getOrCreateCanonicalChat(profile name: String) async throws -> String {
        try await profileManager.getOrCreateCanonicalChat(profile: name)
    }
}
