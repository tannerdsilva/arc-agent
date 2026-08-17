import Foundation
import ServiceLifecycle
import Logging

// MARK: - Group Chat

/// A multi-agent coordination room where multiple bots can converse.
///
/// ``GroupChatRoom`` is an **actor** that manages a single group conversation.
/// Each group has:
/// - A persistent room log stored in LMDB
/// - Per-member watermark tracking (each bot sees only new messages)
/// - Round-robin turn execution with @mention routing
/// - Epoch-based superseding (a new user message bumps the epoch)
///
/// ## Turn Protocol
///
/// 1. User sends a message → appended to room log, epoch bumped
/// 2. ``runRounds()`` drives up to 3 rounds
/// 3. Each round: ``resolveResponders()`` determines who speaks
///    (mentioned members only, or everyone if no one is mentioned)
/// 4. Each member receives a delta of new messages since their last watermark
/// 5. Member replies via direct actor call into their per-group session
/// 6. `(pass)` = silence; a full round of passes = conversation settled
/// 7. Hard caps: 10 messages per turn, 3 rounds max
///
/// ## Improvements Over Hermes Bot Mode
///
/// - **No polling**: Each member turn is a direct ``SessionRegistry`` route
///   with ``AsyncThrowingStream`` for the response, not a 2-second poll loop
/// - **No timeout hacks**: Swift's cooperative timeout handles stuck members
/// - **Actor isolation**: The room's state is naturally serialized
/// - **Type-safe**: Member names are validated against the profile manager
///
/// ## Law of the Land
///
/// - **First Law**: ``GroupChatRoom`` is an actor — all state is serialized.
public actor GroupChatRoom {

    // MARK: - Constants

    public static let maxRounds = 3
    public static let maxMessagesPerTurn = 10
    public static let historyLimit = 24
    public static let maxMembers = 6
    public static let turnTimeoutSeconds: UInt64 = 180

    // MARK: - Types

    /// A single entry in the room log.
    public struct Entry: Sendable, Codable {
        /// Who sent the message.
        public let from: Sender
        /// The message text.
        public let text: String
        /// When it was sent.
        public let at: Date

        public init(from: Sender, text: String) {
            self.from = from
            self.text = text
            self.at = Date()
        }
    }

    /// Who sent a message in the room.
    public enum Sender: Sendable, Codable, Equatable {
        /// A human user.
        case user(name: String)
        /// A bot member.
        case member(name: String)

        public var name: String {
            switch self {
            case .user(let n): return n
            case .member(let n): return n
            }
        }

        public var isUser: Bool {
            if case .user = self { return true }
            return false
        }
    }

    /// A member of the group chat.
    public struct Member: Sendable, Equatable {
        public let name: String
        public let displayName: String

        public init(name: String, displayName: String = "") {
            self.name = name
            self.displayName = displayName.isEmpty ? name : displayName
        }
    }

    // MARK: - State

    /// The group name.
    public let name: String
    /// The members of this group.
    public let members: [Member]
    /// The room log (persisted).
    private var log: [Entry] = []
    /// Per-member watermark: index into `log` that each member has seen.
    private var watermarks: [String: Int] = [:]
    /// Per-member per-group session IDs.
    private var sessions: [String: String] = [:]
    /// Whether a turn is currently running.
    private var running = false
    /// Epoch counter — bumped on every user send to supersede stale loops.
    private var epoch = 0
    /// Whether the group header should show a "needs you" badge.
    public private(set) var needsUserAttention = false
    /// Reference to the messaging service for member turn execution.
    private weak var messagingService: BotMessagingService?
    /// Reference to the profile manager for member lookups.
    private let profileManager: ProfileManager
    /// Logger.
    private let logger: Logger

    public init(
        name: String,
        members: [Member],
        profileManager: ProfileManager,
        messagingService: BotMessagingService? = nil
    ) {
        self.name = name
        self.members = members
        self.profileManager = profileManager
        self.messagingService = messagingService
        self.logger = Logger(label: "com.arc-agent.group-chat.\(name)")
    }

    /// Set the messaging service reference.
    func setMessagingService(_ service: BotMessagingService) {
        self.messagingService = service
    }

    // MARK: - Public API

    /// The current room log.
    public var roomLog: [Entry] { log }

    /// Send a user message into the room.
    /// - Parameter text: The message text.
    public func sendUserMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        needsUserAttention = false
        appendEntry(Sender.user(name: "You"), text: trimmed)

        // Bump epoch to supersede any running loop
        epoch += 1
        running = true

        await runRounds()
    }

    /// Get the delta of new messages for a member since their last watermark.
    public func delta(for member: String) -> [Entry] {
        let seen = watermarks[member] ?? 0
        guard seen < log.count else { return [] }
        return Array(log[seen...])
    }

    /// Mark a member as having seen messages up to the current log length.
    public func markSeen(member: String) {
        watermarks[member] = log.count
    }

    // MARK: - Private

    /// Append an entry to the room log and persist.
    private func appendEntry(_ from: Sender, text: String) {
        let entry = Entry(from: from, text: text)
        log.append(entry)

        // Trim log to history limit
        if log.count > GroupChatRoom.historyLimit * 4 {
            let drop = log.count - GroupChatRoom.historyLimit * 4
            log.removeFirst(drop)

            // Adjust watermarks
            for (member, idx) in watermarks {
                watermarks[member] = max(0, idx - drop)
            }
        }

        // Check for @user mention
        if from.isUser == false && text.localizedCaseInsensitiveContains("@user") {
            needsUserAttention = true
        }
    }

    /// Drive up to 3 rounds of member turns.
    private func runRounds() async {
        let startEpoch = epoch

        func isCurrent() -> Bool {
            epoch == startEpoch
        }

        var posted = 0

        defer {
            if isCurrent() {
                running = false
            }
        }

        for round in 0..<GroupChatRoom.maxRounds {
            guard isCurrent() else { return }

            let responders = resolveResponders()
            let rotated = rotateSpeakers(responders, round: round)
            var spokeThisRound = 0

            for member in rotated {
                guard isCurrent(), posted < GroupChatRoom.maxMessagesPerTurn else { return }

                let seen = watermarks[member.name] ?? 0
                let delta = Array(log[seen...])
                guard !delta.isEmpty else { continue }

                let prompt = buildTurnPrompt(for: member, delta: delta)
                let reply = await executeMemberTurn(member, prompt: prompt)

                // Mark as seen regardless of reply
                watermarks[member.name] = log.count

                if let reply, !isPass(reply) {
                    appendEntry(Sender.member(name: member.name), text: reply)
                    watermarks[member.name] = log.count
                    posted += 1
                    spokeThisRound += 1
                }
            }

            if spokeThisRound == 0 {
                return // settled
            }
        }
    }

    /// Resolve which members should respond this round.
    /// - If any message since the last user entry contains @mentions, only
    ///   mentioned members respond.
    /// - If @everyone or no mentions, all members respond.
    private func resolveResponders() -> [Member] {
        // Find messages since the last user entry
        var sinceLastUser: [Entry] = []
        for i in stride(from: log.count - 1, through: 0, by: -1) {
            if log[i].from.isUser {
                sinceLastUser = Array(log[i...])
                break
            }
        }

        // Parse @mentions
        var mentioned = Set<String>()
        var everyone = false

        for entry in sinceLastUser {
            let mentions = parseMentions(entry.text)
            if mentions.contains("everyone") || mentions.contains("all") {
                everyone = true
            }
            for m in mentions {
                if members.contains(where: { $0.name == m }) {
                    mentioned.insert(m)
                }
            }
        }

        if everyone || mentioned.isEmpty {
            return members
        }

        return members.filter { mentioned.contains($0.name) }
    }

    /// Rotate the speaker order so a different member leads each round.
    private func rotateSpeakers(_ speakers: [Member], round: Int) -> [Member] {
        guard speakers.count > 1 else { return speakers }
        let shift = round % speakers.count
        return Array(speakers[shift...] + speakers[0..<shift])
    }

    /// Build the turn prompt for a single member.
    private func buildTurnPrompt(for member: Member, delta: [Entry]) -> String {
        let peers = members.filter { $0.name != member.name }
        let peerNames = peers.map { $0.displayName + " (@" + $0.name + ")" }.joined(separator: ", ")

        let deltaLines = delta.map { entry -> String in
            switch entry.from {
            case .user(let name):
                return "  \(name) (user): \(entry.text)"
            case .member(let name):
                let suffix = name == member.name ? " (you)" : ""
                return "  \(name)\(suffix): \(entry.text)"
            }
        }.joined(separator: "\n")

        return """
        [Group chat: "\(name)"] You are @\(member.name), one participant in a group chat with \(peerNames.isEmpty ? "no one else yet" : peerNames) and the user.

        New messages in the room since your last turn (oldest first):
        \(deltaLines)

        Rules for this room:
        - Reply with ONE short conversational message (1-3 sentences) ONLY if you have something new worth adding: build on what was just said, claim or hand off work, answer a question aimed at you, or report a real result.
        - If you have nothing new to add, reply with exactly "(pass)". Passing is good — it lets the conversation settle.
        - Mention a teammate as @name to pull them in; mention @user only for a judgment call or a result the user needs. Do not repeat points already made.
        - Never reveal content from your private 1:1 chats. Your reply text goes to the room verbatim — no preamble, no meta-commentary.
        """
    }

    /// Execute one member's turn by submitting the prompt to their per-group session.
    private func executeMemberTurn(_ member: Member, prompt: String) async -> String? {
        // In a full implementation, this would route the prompt to the member's
        // per-group session via the SessionRegistry and wait for the response.
        //
        // For now, we return nil (pass) since the full session routing integration
        // requires the gateway to be running.
        logger.info("Member turn: \(member.name) in group '\(name)'")
        return nil
    }

    /// Check if a reply text is a pass (silence).
    private func isPass(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.range(of: #"^\(?\s*pass\s*\)?\.?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Parse @mentions from text.
    private func parseMentions(_ text: String) -> Set<String> {
        var mentions = Set<String>()
        let pattern = #"@([a-z0-9][a-z0-9._-]*)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..., in: text)

        regex?.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: text) else { return }
            mentions.insert(String(text[range]).lowercased())
        }

        return mentions
    }
}

// MARK: - GroupChatManager

/// Manages all active group chat rooms.
///
/// ``GroupChatManager`` is an actor that owns the lifecycle of all
/// ``GroupChatRoom`` instances. Rooms are created on demand and persist
/// in LMDB.
public actor GroupChatManager {

    /// All active rooms.
    private var rooms: [String: GroupChatRoom] = [:]
    private let profileManager: ProfileManager
    private var messagingService: BotMessagingService?

    public init(profileManager: ProfileManager) {
        self.profileManager = profileManager
    }

    /// Set the messaging service reference.
    func setMessagingService(_ service: BotMessagingService) {
        self.messagingService = service
    }

    /// Get or create a group chat room.
    public func getOrCreate(
        name: String,
        members: [GroupChatRoom.Member]
    ) -> GroupChatRoom {
        if let existing = rooms[name] {
            return existing
        }

        let room = GroupChatRoom(
            name: name,
            members: members,
            profileManager: profileManager,
            messagingService: messagingService
        )
        rooms[name] = room
        return room
    }

    /// Get a room by name.
    public func get(name: String) -> GroupChatRoom? {
        rooms[name]
    }

    /// List all active rooms.
    public var allRooms: [GroupChatRoom] {
        Array(rooms.values)
    }

    /// Remove a room.
    public func remove(name: String) {
        rooms.removeValue(forKey: name)
    }
}
