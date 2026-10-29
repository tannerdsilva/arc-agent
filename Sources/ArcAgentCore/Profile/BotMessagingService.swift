import Foundation
import ServiceLifecycle
import Logging

// MARK: - BotPeerSessions

/// What ``BotMessagingService`` needs from the session layer.
///
/// ``SessionRegistry`` is the production conformer: ``deliver(_:profile:)``
/// opens (or reuses) the recipient's canonical session, and the reply methods
/// forward to the registry's ``BotReplyBus``. The test target supplies an
/// in-memory directory of peers that answer deterministically — that is the
/// only way to prove correlation without a model call, since a real
/// ``SessionAgent`` builds its client inside `run()`.
///
/// Registration is a separate call from delivery on purpose: the waiter must
/// exist **before** the message lands, or a peer that answers during the
/// delivery call publishes into nothing.
protocol BotPeerSessions: Sendable {
    /// Register a waiter for the message id `id`; the reply arrives on it.
    func registerReplyWaiter(id: String) async -> AsyncStream<String>
    /// Put `incoming` into `profile`'s canonical session.
    func deliver(_ incoming: IncomingMessage, profile: String) async
    /// Drop a waiter that will not be answered (timeout, cancellation).
    func cancelReplyWaiter(id: String) async
}

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
/// Unlike arc bot mode (which uses CLI invocation for bot-to-bot delivery),
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
    /// The session layer, once a host has wired one: delivery in, replies out.
    private var peers: (any BotPeerSessions)?
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

    /// A service bound to a session layer the caller supplies.
    ///
    /// The daemon does not use this — it wires the real ``SessionRegistry``
    /// through ``SessionRegistry/setMessagingService(_:)`` — but a test can hand
    /// over in-memory peers and prove the reply path without a model call.
    init(profileManager: ProfileManager, peers: any BotPeerSessions) {
        self.profileManager = profileManager
        self.peers = peers
        self.logger = Logger(label: "com.arc-agent.bot-messaging")

        var continuation: AsyncStream<ActivityEvent>.Continuation!
        self.activityStream = AsyncStream { continuation = $0 }
        self.activityContinuation = continuation
    }

    /// Set the session layer (called during session-host wiring).
    ///
    /// ``SessionRegistry/setMessagingService(_:)`` calls this itself, so the
    /// delivery path and the reply channel are installed together.
    func setSessionRegistry(_ registry: SessionRegistry) {
        self.peers = registry
    }

    // MARK: - Service

    public func run() async throws {
        logger.info("Bot messaging service started")

        // The service runs until cancelled — it holds the activity stream
        // continuation and the session registry reference. `runUntilShutdown`
        // turns the group's graceful shutdown into that cancellation, so
        // SIGTERM stops it promptly instead of waiting out the grace period.
        try await runUntilShutdown {
            try await Task.sleep(nanoseconds: UInt64.max)
        }
    }

    // MARK: - Sending Messages

    /// Send a message from one bot to another.
    ///
    /// Unlike arc bot mode (which shells out to `reference -p <target> chat ...`),
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

        // If a session layer is wired, deliver directly into the recipient's
        // session. The recipient bot will see the message on its next turn.
        if let peers {
            let canonicalChatID = try await profileManager.getOrCreateCanonicalChat(profile: message.to)
            let incoming = IncomingMessage(
                id: message.id,
                chat: ChatTarget(platform: "bot", chatID: canonicalChatID),
                text: message.formattedText,
                senderID: message.from
            )
            await peers.deliver(incoming, profile: message.to)
        }
    }

    /// How long ``sendMessageAndWait(_:)`` waits for the peer's turn to finish.
    ///
    /// A peer that never answers must not hold the caller open: past this bound
    /// the stream ends without a value, and the tool renders its honest timeout
    /// sentence. The tool bounds its *own* wait too (injectable, for tests);
    /// whichever fires first, the answer is the same sentence.
    public static let replyTimeout: Duration = .seconds(60)

    /// Send a message and wait for the peer's reply.
    ///
    /// The reply is correlated to **this** message: a waiter is registered under
    /// `message.id` before delivery, and the recipient's turn publishes its
    /// final text under the id of the message that started that turn. Two
    /// concurrent senders to the same peer therefore each collect their own
    /// answer — ``SessionHandle/responses``, a single-consumer stream, is never
    /// read here.
    ///
    /// - Parameters:
    ///   - message: The message to send.
    /// - Returns: A stream carrying the peer's reply text, or no value when the
    ///   peer did not answer inside ``replyTimeout``.
    public func sendMessageAndWait(_ message: BotMessage) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let wait = Task {
                guard let peers = self.peers else {
                    // No session layer is wired: nothing can carry an answer.
                    continuation.finish()
                    return
                }
                // Register BEFORE delivering: a peer that answers inside
                // `sendMessage` must not outrun its waiter.
                let replies = await peers.registerReplyWaiter(id: message.id)
                guard !Task.isCancelled else {
                    await peers.cancelReplyWaiter(id: message.id)
                    continuation.finish()
                    return
                }
                do {
                    try await self.sendMessage(message)
                } catch {
                    await peers.cancelReplyWaiter(id: message.id)
                    continuation.finish(throwing: error)
                    return
                }
                let reply = await Self.firstReply(replies, timeout: Self.replyTimeout)
                // Answered: `publish` already removed the waiter. Timed out or
                // cancelled: drop it, so a waiter never outlives its question.
                await peers.cancelReplyWaiter(id: message.id)
                if let reply, !reply.isEmpty {
                    continuation.yield(reply)
                }
                continuation.finish()
            }
            // A caller that stopped reading (its own bound expired) takes the
            // waiter with it instead of leaving it to this stream's deadline.
            continuation.onTermination = { _ in wait.cancel() }
        }
    }

    /// Ask one participant a question and wait for its answer.
    ///
    /// This is the group-room half of the correlated reply primitive. It is
    /// deliberately **not** ``sendMessage(_:)``: that path derives the sender's
    /// identity from `message.from` and validates it against the roster, but a
    /// room turn originates from the user or the room itself — never from a
    /// profile — so there is no profile id to validate. Here the sender is
    /// synthetic: `group:<room>`.
    ///
    /// The prompt is delivered into `profile`'s **per-room** session
    /// (`group-<room>`), not its canonical bot chat, so a member's room context
    /// stays separate from its one-to-one conversations.
    ///
    /// - Parameters:
    ///   - prompt: The room turn prompt, delivered verbatim.
    ///   - profile: The member's profile name.
    ///   - room: The room the turn belongs to; names the synthetic sender and
    ///     keys the member's per-room session.
    /// - Returns: The member's final text, or `nil` when nothing came back —
    ///   no session layer wired, no such profile, the bound expired, or the
    ///   turn produced no text. The waiter is cancelled on every one of those
    ///   paths, so a silent member never leaves one registered.
    func ask(prompt: String, profile: String, room: String) async -> String? {
        guard let peers else { return nil }
        guard ((try? await profileManager.get(name: profile)) ?? nil) != nil else {
            logger.debug("Group turn skipped: no profile named '\(profile)'")
            return nil
        }

        let id = "group-turn-\(UUID().uuidString)"
        // Register BEFORE delivering: a member that answers immediately must
        // not outrun its waiter.
        let replies = await peers.registerReplyWaiter(id: id)
        guard !Task.isCancelled else {
            await peers.cancelReplyWaiter(id: id)
            return nil
        }

        await peers.deliver(
            IncomingMessage(
                id: id,
                chat: ChatTarget(platform: "group", chatID: "group-\(room)"),
                text: prompt,
                senderID: "group:\(room)",
                senderName: room
            ),
            profile: profile
        )

        let reply = await Self.firstReply(replies, timeout: Self.replyTimeout)
        // Answered: `publish` already removed the waiter. Timed out or
        // cancelled: drop it here, so it never outlives the question.
        await peers.cancelReplyWaiter(id: id)

        guard let reply, !reply.isEmpty else { return nil }
        return reply
    }

    /// The first value the peer publishes, or `nil` when the bound expires
    /// first.
    ///
    /// Whichever task finishes first wins; the other is cancelled, so a peer
    /// that never answers costs the caller the bound and nothing more.
    private static func firstReply(_ stream: AsyncStream<String>, timeout: Duration) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await reply in stream { return reply }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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
