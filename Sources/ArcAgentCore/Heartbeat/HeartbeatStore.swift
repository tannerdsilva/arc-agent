import Foundation

// MARK: - Session heartbeats (Hermes `features/heartbeat.md`)

/// A session heartbeat is one recurring instruction that re-enters the
/// session as a plain user turn whenever the session is idle and the
/// interval has elapsed. `/heartbeat every 10m <prompt>`, alias `/hb`.
public struct Heartbeat: Sendable, Codable, Equatable {
    /// Interval in seconds (minimum 60).
    public var intervalSeconds: Int
    /// The recurring instruction.
    public var prompt: String
    /// Paused: keeps the record but stops firing.
    public var paused: Bool
    /// When the next heartbeat may fire (epoch seconds).
    public var nextFireAt: Date
    /// The chat this heartbeat delivers into (persisted so a restart
    /// doesn't lose the delivery target).
    public var chat: ChatTarget

    public init(
        intervalSeconds: Int,
        prompt: String,
        paused: Bool = false,
        nextFireAt: Date = Date(),
        chat: ChatTarget
    ) {
        self.intervalSeconds = intervalSeconds
        self.prompt = prompt
        self.paused = paused
        self.nextFireAt = nextFireAt
        self.chat = chat
    }
}

/// Parses Hermes heartbeat intervals: `90s`, `10m`, `2h`, `1d`.
/// Returns nil for malformed or sub-minute intervals (spec minimum 60s).
public enum HeartbeatInterval {
    public static func parse(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var multiplier = 1
        if text.hasSuffix("s") { text = String(text.dropLast()) }
        else if text.hasSuffix("m") { multiplier = 60; text = String(text.dropLast()) }
        else if text.hasSuffix("h") { multiplier = 3600; text = String(text.dropLast()) }
        else if text.hasSuffix("d") { multiplier = 86400; text = String(text.dropLast()) }
        guard let value = Int(text), value > 0 else { return nil }
        let seconds = value * multiplier
        guard seconds >= 60 else { return nil }
        return seconds
    }

    public static func format(_ seconds: Int) -> String {
        if seconds % 86400 == 0 { return "\(seconds / 86400)d" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}

/// Durable per-session heartbeat state (Hermes `SessionDB.state_meta`
/// keyed by `heartbeat:<session_id>`).
public actor HeartbeatStore {

    /// Storage file (overridden in tests via ``setStorageURL``).
    private static var storageURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".arc/heartbeats.json")

    public static func setStorageURL(_ url: URL) {
        storageURL = url
    }

    private var records: [String: Heartbeat] = [:]

    public init() {}

    public init(loadFrom url: URL? = nil) throws {
        let target = url ?? Self.storageURL
        if let data = try? Data(contentsOf: target),
           let decoded = try? JSONDecoder().decode([String: Heartbeat].self, from: data) {
            records = decoded
        }
    }

    // MARK: - Mutations

    /// Set (or replace) the session's heartbeat.
    public func set(
        sessionID: String,
        intervalSeconds: Int,
        prompt: String,
        chat: ChatTarget,
        nextFireAt: Date? = nil
    ) {
        records[sessionID] = Heartbeat(
            intervalSeconds: intervalSeconds,
            prompt: prompt,
            nextFireAt: nextFireAt ?? Date().addingTimeInterval(TimeInterval(intervalSeconds)),
            chat: chat
        )
    }

    public func pause(sessionID: String) {
        guard var record = records[sessionID] else { return }
        record.paused = true
        records[sessionID] = record
    }

    public func resume(sessionID: String) {
        guard var record = records[sessionID] else { return }
        record.paused = false
        // Re-anchor the timer — no instant stale fire.
        record.nextFireAt = Date().addingTimeInterval(TimeInterval(record.intervalSeconds))
        records[sessionID] = record
    }

    public func clear(sessionID: String) {
        records[sessionID] = nil
    }

    /// The gateway learns the delivery chat from the session's first real
    /// message and adopts it so CLI-set heartbeats deliver correctly.
    public func adoptChat(sessionID: String, chat: ChatTarget) {
        guard var record = records[sessionID] else { return }
        guard record.chat.platform.isEmpty else { return }
        record.chat = chat
        records[sessionID] = record
    }

    // MARK: - Queries

    public func status(sessionID: String) -> Heartbeat? {
        records[sessionID]
    }

    /// All heartbeat records (for status listings).
    public func all() -> [String: Heartbeat] {
        records
    }

    /// Returns the heartbeat if it is due (and not paused), and re-anchors
    /// `nextFireAt` so one fire per interval (missed ticks coalesce).
    public func consumeIfDue(sessionID: String, now: Date = Date()) -> Heartbeat? {
        guard var record = records[sessionID] else { return nil }
        guard !record.paused else { return nil }
        guard record.nextFireAt <= now else { return nil }
        record.nextFireAt = now.addingTimeInterval(TimeInterval(record.intervalSeconds))
        records[sessionID] = record
        return record
    }

    // MARK: - Persistence

    public func save() throws {
        let target = Self.storageURL
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: target, options: .atomic)
    }
}
