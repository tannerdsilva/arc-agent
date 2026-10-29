import ArcToolKit
import Foundation
import SwiftSlash

// MARK: - ProfileManager

/// The roster's roster-shaped façade over a ``ProfileStore``.
///
/// This type used to *be* the store: its own cache, its own read-modify-write
/// of `index.json`, its own Tessera branch. That logic now lives in
/// ``FileProfileStore`` (the index + `config.json` format) and
/// ``TesseraProfileStore`` (the kind-3004 branch, which degrades to that same
/// file format), behind the ``ProfileStore`` port and the one
/// ``ProfileService`` that owns it.
///
/// `ProfileManager` remains, unchanged in surface, so that the 19 existing
/// `ProfileManager()` call sites (`arc-agent/Arc.swift`, `ArcWebUI/AppState`,
/// the roster tools, `SessionHost`) keep compiling and keep behaving. What it
/// no longer has is a private cache that disagrees with another instance:
/// every operation delegates to the store, which serializes its own writes.
///
/// **This shim is transitional.** It is still one *instance* per call site, but
/// every instance delegates to the same process-wide store, so the 19 sites
/// already share one writer and one cache. What slice 4 adds is the service
/// handle (a lifetime and a single injection point), not the serialization.
///
/// ## Law of the Land
///
/// - **First Law**: state is guarded by the store's actor.
/// - **Second Law**: long-lived ownership belongs to ``ProfileService``, a
///   `Service` in the daemon's tree. A shim is for call sites that have no
///   service handle yet.
public actor ProfileManager {

    // MARK: - Paths

    /// Base URL for profile storage (~/.arc/profiles/).
    public static var profilesDir: String {
        if let override = testProfilesRoot, !override.isEmpty { return override }
        return ArcHome.profiles.path
    }

    /// Test seam: when set, overrides the profile storage root so tests never
    /// touch the real `~/.arc/profiles` directory. Honoured by the store the
    /// shim delegates to, which resolves it per operation.
    public nonisolated(unsafe) static var testProfilesRoot: String?

    /// Path to the index file used when Tessera storage is not configured.
    public static var indexFilePath: String {
        "\(profilesDir)/index.json"
    }

    /// Path to a profile's sessions directory.
    public static func sessionsDirectory(for profile: String) -> String {
        "\(profilesDir)/\(profile)/sessions"
    }

    /// Path to a profile's schema/config file.
    public static func configPath(for profile: String) -> String {
        "\(profilesDir)/\(profile)/config.json"
    }

    /// Per-profile memory file (arc profiles: each profile has its own
    /// MEMORY.md / USER.md; `nil` until created, since providers create on
    /// write).
    public static func memoryURL(for profile: String) -> URL? {
        let dir = URL(fileURLWithPath: profilesDir).appendingPathComponent(profile, isDirectory: true)
        return dir
    }

    /// Per-profile skills directory (reference `~/.reference/profiles/<name>/skills`).
    public static func skillsURL(for profile: String) -> URL? {
        let dir = URL(fileURLWithPath: profilesDir).appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        return dir
    }

    /// Path to a profile's .env file (API key overrides).
    public static func envPath(for profile: String) -> String {
        "\(profilesDir)/\(profile)/.env"
    }

    // MARK: - State

    /// The one writer this shim delegates to.
    ///
    /// Deliberately the process-wide ``TesseraProfileStore/shared`` rather than
    /// a fresh ``FileProfileStore``: the file store *is* this backend when
    /// Tessera is unconfigured, and the Tessera branch must stay live for the
    /// 19 existing call sites (a daemon with a tunnel would otherwise silently
    /// start writing `index.json`). One instance also means one cache, so two
    /// shims cannot hold divergent rosters the way 19 independent managers did.
    private let store: any ProfileStore

    public init() {
        self.store = TesseraProfileStore.shared
    }

    /// Inject the roster backend (tests, fixtures). Pass a store whose root
    /// matches ``profilesDir`` — `create`, `export`, and `importDistribution`
    /// still read the static path helpers directly.
    public init(store: any ProfileStore) {
        self.store = store
    }

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
        guard let profileName = ProfileName(name) else {
            throw ProfileError.invalidName(name)
        }

        guard try await store.get(profileName) == nil else {
            throw ProfileError.duplicateName(name)
        }

        // Create the profile
        var profile = Profile(name: name)

        // Clone from existing profile if specified
        if let source = cloneFrom,
           let sourceName = ProfileName(source),
           let sourceProfile = try await store.get(sourceName) {
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
            at: URL(fileURLWithPath: Self.sessionsDirectory(for: name)),
            withIntermediateDirectories: true
        )

        // Persist the profile record (Tessera or JSON index)
        try await store.put(profile)

        return profile
    }

    /// Export a profile as a distribution archive (reference
    /// `profile_distribution.py`): zip of the profile directory rooted at
    /// `<name>/`. Returns the archive path.
    public func export(name: String, to outputURL: URL) async throws -> URL {
        guard profileSaved(name: name) else {
            throw ProfileError.notFound(name)
        }
        let profilesRoot = URL(fileURLWithPath: Self.profilesDir)
        let archive = outputURL
        let command = Command(
            absolutePath: Path("/bin/bash"),
            arguments: ["-c",
                "cd \(shellQuote(profilesRoot.path)) && rm -f \(shellQuote(archive.path)) && zip -qr \(shellQuote(archive.path)) \(shellQuote(name))"]
        )
        let outcome = try await SubprocessRunner.runBytes(command, timeout: 60)
        guard outcome.exitCode == 0 else {
            throw ProfileError.exportFailed(String(decoding: outcome.stderr, as: UTF8.self))
        }
        return archive
    }

    /// Import a profile distribution archive produced by ``export(name:to:)``:
    /// unzips into the profiles root, extracting the `<name>/` directory.
    /// Returns the imported profile name.
    public func importDistribution(from archiveURL: URL) async throws -> String {
        let profilesRoot = URL(fileURLWithPath: Self.profilesDir)
        let command = Command(
            absolutePath: Path("/bin/bash"),
            arguments: ["-c",
                "cd \(shellQuote(profilesRoot.path)) && unzip -qo \(shellQuote(archiveURL.path))"]
        )
        let outcome = try await SubprocessRunner.runBytes(command, timeout: 60)
        guard outcome.exitCode == 0 else {
            throw ProfileError.importFailed(String(decoding: outcome.stderr, as: UTF8.self))
        }
        // The archive root names the profile: find a directory whose
        // config.json parses as a Profile (parse-first, not alphabetical).
        let entries = try FileManager.default.contentsOfDirectory(
            at: profilesRoot, includingPropertiesForKeys: nil
        )
        var importedName: String?
        var importedProfile: Profile?
        for dir in entries {
            let configURL = dir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: configURL),
                  let profile = try? JSONDecoder().decode(Profile.self, from: data) else { continue }
            importedName = dir.lastPathComponent
            importedProfile = profile
            break
        }
        guard let name = importedName else {
            throw ProfileError.importFailed("archive contains no valid profile config.json")
        }

        // Sync the index with the imported record.
        if let profile = importedProfile {
            try await store.put(profile)
        }
        return name
    }

    private func profileSaved(name: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.configPath(for: name))
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Get a profile by name, or `nil` when the roster has none. An invalid
    /// name can never match a record, so it is `nil` rather than an error —
    /// the same answer the old cache lookup gave.
    public func get(name: String) async throws -> Profile? {
        guard let profileName = ProfileName(name) else { return nil }
        return try await store.get(profileName)
    }

    /// List all profiles, sorted by creation date (newest first).
    public func list() async throws -> [Profile] {
        try await store.list()
    }

    /// Update an existing profile.
    public func update(_ profile: Profile) async throws {
        guard let name = ProfileName(profile.name),
              try await store.get(name) != nil else {
            throw ProfileError.notFound(profile.name)
        }

        var updated = profile
        updated.updatedAt = Date()

        try await store.put(updated)
    }

    /// Delete a profile and all its data.
    public func delete(name: String) async throws {
        guard name != "default" else {
            throw ProfileError.cannotDeleteDefault
        }
        guard let profileName = ProfileName(name),
              try await store.get(profileName) != nil else {
            throw ProfileError.notFound(name)
        }

        try await store.delete(profileName)
    }

    /// Get or create the canonical "Bot Chat" session ID for a profile.
    public func getOrCreateCanonicalChat(profile name: String) async throws -> String {
        _ = try await get(name: name) ?? Profile(name: name)

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

}

// MARK: - Messaging Protocol Section

/// The agent-to-agent messaging protocol section appended to a daemon
/// session's system message when its surface carries `send_bot_message`.
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

/// The system message a daemon session injects, or `nil` when there is nothing
/// to say.
///
/// The profile's SOUL leads. The agent-to-agent protocol follows **only when
/// this session's surface carries `send_bot_message`** — messaging is
/// register-when-available (D21), so the registry lookup that finds the tool is
/// the same decision that appends the text describing it, and a `Bool` threaded
/// from the caller cannot promise a protocol the surface does not have.
///
/// A SOUL that already documents the protocol is left alone: an operator's own
/// copy wins over a second one.
func sessionSystemMessage(
    soul: String?,
    registry: any ToolRegistry,
    profile: Profile,
    roster: [Profile]
) -> String? {
    var sections: [String] = []

    if let soul {
        // Trimmed so the sections are separated by exactly one blank line,
        // whatever trailing newline the SOUL document was saved with.
        let text = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { sections.append(text) }
    }

    if registry.lookup(name: "send_bot_message") != nil {
        let messaging = messagingProtocolSection(
            name: profile.name,
            displayName: profile.displayName,
            teammates: roster.filter { $0.name != profile.name }
        )
        // The heading is read off the section itself: the product copy exists
        // exactly once, in `messagingProtocolSection`, so this dedupe cannot
        // drift from the text it is checking for.
        let heading = messaging.components(separatedBy: "\n").first ?? messaging
        if !(soul?.contains(heading) ?? false) {
            sections.append(messaging)
        }
    }

    let message = sections.joined(separator: "\n\n")
    return message.isEmpty ? nil : message
}
