import Foundation

// MARK: - ProfileManager

/// Manages the lifecycle of agent profiles.
///
/// ``ProfileManager`` is an **actor** — all state mutations are serialized.
/// It uses LMDB for durable storage:
/// - Profile index in `global.mdb` (database: `profiles`)
/// - Per-profile memory in `profiles/<name>/memory.mdb`
/// - Per-profile sessions in `profiles/<name>/sessions/<id>.mdb`
///
/// ## Law of the Land
///
/// - **First Law**: ``ProfileManager`` is an actor — all mutable state is
///   guarded by the actor's serial executor.
/// - **Second Law**: ``ProfileManager`` is a ``Service`` in the lifecycle
///   tree when run as a long-lived daemon.
public actor ProfileManager {

    // MARK: - Paths

    /// Base URL for profile storage (~/.arc/profiles/).
    public static var profilesDir: String {
        LMDBManager.baseURL.appendingPathComponent("profiles", isDirectory: true).path
    }

    /// Path to a profile's memory.mdb file.
    public static func memoryPath(for profile: String) -> String {
        "\(profilesDir)/\(profile)/memory.mdb"
    }

    /// Path to a profile's sessions directory.
    public static func sessionsDir(for profile: String) -> String {
        "\(profilesDir)/\(profile)/sessions"
    }

    /// Path to a profile's session .mdb file.
    public static func sessionPath(for profile: String, sessionID: String) -> String {
        "\(sessionsDir(for: profile))/\(sessionID).mdb"
    }

    /// Path to a profile's config overrides file.
    public static func configPath(for profile: String) -> String {
        "\(profilesDir)/\(profile)/config.json"
    }

    /// Path to a profile's .env file (API key overrides).
    public static func envPath(for profile: String) -> String {
        "\(profilesDir)/\(profile)/.env"
    }

    // MARK: - State

    /// In-memory cache of loaded profiles (avoids LMDB reads on every list).
    private var cache: [String: Profile] = [:]
    /// Whether the cache has been seeded from LMDB.
    private var cacheSeeded = false

    public init() {}

    // MARK: - CRUD Operations

    /// Create a new profile.
    /// - Parameters:
    ///   - name: Unique profile name.
    ///   - cloneFrom: Optional existing profile to clone config from.
    /// - Returns: The created profile.
    /// - Throws: ``ProfileError/invalidName``, ``ProfileError/duplicateName``.
    public func create(name: String, cloneFrom: String? = nil) async throws -> Profile {
        guard validateProfileName(name) else {
            throw ProfileError.invalidName(name)
        }

        try await seedCache()

        guard cache[name] == nil else {
            throw ProfileError.duplicateName(name)
        }

        // Create the profile
        var profile = Profile(name: name)

        // Clone from existing profile if specified
        if let source = cloneFrom, let sourceProfile = cache[source] {
            profile.title = sourceProfile.title
            profile.description = sourceProfile.description
            profile.model = sourceProfile.model
            profile.provider = sourceProfile.provider
            profile.baseURL = sourceProfile.baseURL
            profile.enabledToolsets = sourceProfile.enabledToolsets
            profile.disabledToolsets = sourceProfile.disabledToolsets
            profile.soulMD = sourceProfile.soulMD
            profile.avatar = sourceProfile.avatar
        }

        // Create filesystem directories
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: Self.profilesDir).appendingPathComponent(name),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: Self.sessionsDir(for: name)),
            withIntermediateDirectories: true
        )

        // Persist to LMDB
        try await persistProfile(profile)

        // Update cache
        cache[name] = profile

        return profile
    }

    /// Get a profile by name.
    public func get(name: String) async throws -> Profile? {
        try await seedCache()
        return cache[name]
    }

    /// List all profiles, sorted by creation date (newest first).
    public func list() async throws -> [Profile] {
        try await seedCache()
        return cache.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Update an existing profile.
    public func update(_ profile: Profile) async throws {
        try await seedCache()
        guard cache[profile.name] != nil else {
            throw ProfileError.notFound(profile.name)
        }

        var updated = profile
        updated.updatedAt = Date()

        try await persistProfile(updated)
        cache[updated.name] = updated
    }

    /// Delete a profile and all its data.
    public func delete(name: String) async throws {
        guard name != "default" else {
            throw ProfileError.cannotDeleteDefault
        }

        try await seedCache()
        guard cache[name] != nil else {
            throw ProfileError.notFound(name)
        }

        // Remove from LMDB index
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let env = try LMDBManager.openGlobal()
                defer { LMDB.envClose(env) }

                let txn = try LMDB.txnBeginWrite(env: env)
                defer { LMDB.txnAbort(txn) }

                let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "profiles", create: false)
                let keyBytes = [UInt8](name.utf8)
                _ = try LMDB.del(env: env, txn: txn, dbi: dbi, key: keyBytes)
                try LMDB.txnCommit(txn)

                continuation.resume()
            } catch {
                continuation.resume(throwing: ProfileError.storageError(error.localizedDescription))
            }
        }

        // Remove filesystem data
        let profileDir = URL(fileURLWithPath: Self.profilesDir).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: profileDir)

        // Update cache
        cache.removeValue(forKey: name)
    }

    /// Get or create the canonical "Bot Chat" session ID for a profile.
    public func getOrCreateCanonicalChat(profile name: String) async throws -> String {
        let profile = try await get(name: name) ?? Profile(name: name)

        // Check if a canonical chat ID is stored in the profile's metadata
        // We store it as a file in the profile directory
        let chatIDPath = "\(Self.profilesDir)/\(name)/canonical_chat.txt"

        if let existing = try? String(contentsOfFile: chatIDPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        // Create a new canonical chat session
        let sessionID = "bot-chat-\(name)-\(UUID().uuidString.prefix(8))"
        try sessionID.write(toFile: chatIDPath, atomically: true, encoding: .utf8)

        return sessionID
    }

    /// Generate the default SOUL.md content for a profile.
    public static func defaultSoul(for profile: Profile, roster: [Profile]) -> String {
        let teammates = roster.filter { $0.name != profile.name }
        let lines = [
            "# \(profile.displayName)",
            "",
            profile.title.isEmpty ? nil : "**Role:** \(profile.title)",
            profile.description.isEmpty ? nil : "**Mission:** \(profile.description)",
            "",
            "You are \(profile.displayName), a persistent named agent (profile `\(profile.name)`) on this machine.",
            "You keep your own memory, skills, and conversation history across sessions.",
            "",
            messagingProtocolSection(name: profile.name, displayName: profile.displayName, teammates: teammates)
        ]

        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    // MARK: - Private

    /// Seed the in-memory cache from LMDB.
    private func seedCache() async throws {
        guard !cacheSeeded else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let env = try LMDBManager.openGlobal()
                defer { LMDB.envClose(env) }

                let txn = try LMDB.txnBeginRead(env: env)
                defer { LMDB.txnAbort(txn) }

                let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "profiles", create: true)

                // Read all profiles from the database
                let cursor = try LMDB.cursorOpen(txn: txn, dbi: dbi)
                defer { LMDB.cursorClose(cursor) }

                // Position cursor at the first entry
                if let (k, v) = try LMDB.cursorSetRange(cursor: cursor, key: []) {
                    let name = String(decoding: k, as: UTF8.self)
                    if let profile = try? JSONDecoder().decode(Profile.self, from: Data(v)) {
                        self.cache[name] = profile
                    }

                    // Iterate remaining entries
                    while let (nextKey, nextValue) = try LMDB.cursorNext(cursor: cursor) {
                        let n = String(decoding: nextKey, as: UTF8.self)
                        if let p = try? JSONDecoder().decode(Profile.self, from: Data(nextValue)) {
                            self.cache[n] = p
                        }
                    }
                }

                // Ensure the "default" profile always exists
                if self.cache["default"] == nil {
                    let defaultProfile = Profile(name: "default", title: "ARC Agent", description: "The primary agent.")
                    let data = try JSONEncoder().encode(defaultProfile)
                    try LMDB.set(env: env, txn: txn, dbi: dbi, key: [UInt8]("default".utf8), value: [UInt8](data))
                    try LMDB.txnCommit(txn)
                    self.cache["default"] = defaultProfile
                } else {
                    try LMDB.txnAbort(txn)
                }

                self.cacheSeeded = true
                continuation.resume()
            } catch {
                continuation.resume(throwing: ProfileError.storageError(error.localizedDescription))
            }
        }
    }

    /// Persist a profile to LMDB.
    private func persistProfile(_ profile: Profile) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let env = try LMDBManager.openGlobal()
                defer { LMDB.envClose(env) }

                let txn = try LMDB.txnBeginWrite(env: env)
                defer { LMDB.txnAbort(txn) }

                let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "profiles", create: true)
                let data = try JSONEncoder().encode(profile)
                try LMDB.set(env: env, txn: txn, dbi: dbi, key: [UInt8](profile.name.utf8), value: [UInt8](data))
                try LMDB.txnCommit(txn)

                continuation.resume()
            } catch {
                continuation.resume(throwing: ProfileError.storageError(error.localizedDescription))
            }
        }
    }
}

// MARK: - Messaging Protocol Section

/// The agent-to-agent messaging protocol section appended to every SOUL.md.
/// This teaches each bot how to communicate with its peers.
public func messagingProtocolSection(
    name: String,
    displayName: String,
    teammates: [Profile]
) -> String {
    let lines = [
        "## Messaging other agents",
        "",
        "You work alongside other named agents. Every agent (including you) has",
        "ONE canonical conversation titled \"Bot Chat\" — created with the agent,",
        "so it always exists. Agent-to-agent messages are delivered straight",
        "into it, like a DM.",
        "",
        "### Sending a message",
        "",
        "To message a teammate, compose a clear message and use the `send_bot_message` tool:",
        "",
        "```",
        "send_bot_message(target: \"<agent-name>\", message: \"your message here\")",
        "```",
        "",
        "Always prefix your message with \"Message from \(displayName) (@\(name)):\" so",
        "the recipient knows who is talking.",
        "",
        "### Receiving messages",
        "",
        "If a message in your Bot Chat starts with \"Message from\", it is",
        "a teammate messaging you, not the user. Answer it directly — your reply",
        "reaches them via their own delivery.",
        "",
        "### @-mention handoffs",
        "",
        "When the user writes @<agent-name> or says \"ask <name> to ...\" /",
        "\"tell <name> ...\", that is a handoff: message that agent, wait for the",
        "reply, and report back.",
        "",
        "### Your teammates",
        "",
        teammates.isEmpty
            ? "(none yet — the roster grows over time)"
            : teammates.map { t in
                "  - `\(t.name)`\(t.title.isEmpty ? "" : " — \(t.title)")"
            }.joined(separator: "\n"),
        "",
        "### Group chats",
        "",
        "You may also participate in group chat rooms with multiple agents.",
        "In a group chat, reply with ONE short conversational message (1-3 sentences)",
        "only if you have something new worth adding. If you have nothing to add,",
        "reply with exactly \"(pass)\". Mention a teammate as @name to pull them in;",
        "mention @user only for a judgment call.",
    ]

    return lines.joined(separator: "\n")
}
