import Foundation

// MARK: - ProfileManager

/// Manages the lifecycle of agent profiles.
///
/// ``ProfileManager`` is an **actor** — all state mutations are serialized.
/// The profile index is persisted as signed NOSTR events (kind 3004) to a
/// Tessera server when Tessera storage is configured, and to a JSON index
/// file under `~/.arc/profiles/index.json` otherwise:
/// - Profile index in Tessera (`arc/p/<name>/<seq>`) or `index.json`
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
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/profiles", isDirectory: true).path
    }

    /// Path to the index file used when Tessera storage is not configured.
    public static var indexFilePath: String {
        "\(profilesDir)/index.json"
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

    /// In-memory cache of loaded profiles (avoids index reads on every list).
    private var cache: [String: Profile] = [:]
    /// Whether the cache has been seeded from the profile index.
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

        // Persist the profile record (Tessera or JSON index)
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

        // Remove from the profile index (Tessera or JSON file)
        if await TesseraConnection.shared.isConfigured {
            try await TesseraConnection.shared.deleteAll(
                dTagPrefix: "arc/p/\(name)/",
                kind: TesseraConnection.profileKind
            )
        } else {
            var index = loadProfilesFromIndexFile()
            index.removeValue(forKey: name)
            try writeIndexFile(index)
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

    /// Seed the in-memory cache from the profile index (Tessera events or
    /// the JSON index file).
    private func seedCache() async throws {
        guard !cacheSeeded else { return }

        do {
            var loaded: [String: Profile] = [:]
            if await TesseraConnection.shared.isConfigured {
                loaded = try await loadProfilesFromTessera()
            } else {
                loaded = loadProfilesFromIndexFile()
            }

            // Ensure the "default" profile always exists
            if loaded["default"] == nil {
                let defaultProfile = Profile(name: "default", title: "ARC Agent", description: "The primary agent.")
                loaded["default"] = defaultProfile
                _ = try? await persistProfile(defaultProfile)
            }

            self.cache = loaded
            self.cacheSeeded = true
        } catch {
            throw ProfileError.storageError(error.localizedDescription)
        }
    }

    /// Load the newest profile record per name from Tessera.
    private func loadProfilesFromTessera() async throws -> [String: Profile] {
        let conn = TesseraConnection.shared
        try await conn.ensureStarted()
        var latest: [String: (seq: Int, profile: Profile)] = [:]
        for record in await conn.snapshot(kind: TesseraConnection.profileKind) {
            guard let dTag = record.dTag,
                  dTag.hasPrefix("arc/p/"),
                  let seq = TesseraConnection.sequenceNumber(fromTagKey: dTag),
                  let profile = try? JSONDecoder().decode(Profile.self, from: Data(record.content.utf8)) else {
                continue
            }
            if let existing = latest[profile.name], existing.seq > seq { continue }
            latest[profile.name] = (seq, profile)
        }
        return latest.mapValues(\.profile)
    }

    /// Load the profile index from `~/.arc/profiles/index.json`.
    private func loadProfilesFromIndexFile() -> [String: Profile] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.indexFilePath)),
              let index = try? JSONDecoder().decode([String: Profile].self, from: data) else {
            return [:]
        }
        return index
    }

    /// Write the profile index to `~/.arc/profiles/index.json`.
    private func writeIndexFile(_ index: [String: Profile]) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: Self.profilesDir),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(index)
        try data.write(to: URL(fileURLWithPath: Self.indexFilePath), options: .atomic)
    }

    /// Persist a profile to Tessera (when configured) or the JSON index.
    private func persistProfile(_ profile: Profile) async throws {
        if await TesseraConnection.shared.isConfigured {
            let conn = TesseraConnection.shared
            try await conn.ensureStarted()
            let seq = await conn.takeSequence()
            let content = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
            try await conn.publish(
                kind: TesseraConnection.profileKind,
                dTagValue: "arc/p/\(profile.name)/\(seq)",
                content: content
            )
        } else {
            var index = loadProfilesFromIndexFile()
            index[profile.name] = profile
            try writeIndexFile(index)
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
