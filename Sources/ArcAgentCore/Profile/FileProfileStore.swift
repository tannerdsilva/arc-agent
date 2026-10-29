import ArcToolKit
import Foundation

// MARK: - FileProfileStore

/// The file-backed roster: `profiles/index.json` plus
/// `profiles/<name>/config.json`.
///
/// This is `ProfileManager`'s JSON branch extracted, not redesigned:
///
/// - the index is the list cache; `profiles/<name>/config.json` is the
///   authoritative full record and wins over a stale index entry
///   (``overlayWithConfig(_:root:)``) — the documented "active profile
///   overrides model/provider/context from config.json" rule;
/// - every index and config write is `.atomic`;
/// - the `default` profile is created on first access;
/// - `ProfileManager.testProfilesRoot` still redirects the whole store.
///
/// **One writer.** The actor's serial executor owns the read-modify-write of
/// `index.json`. Two `put`s cannot interleave, which is exactly the entry loss
/// that motivated the port: 19 independent `ProfileManager` instances used to
/// load the index, mutate their own copy, and write it back over each other.
public actor FileProfileStore: ProfileStore {

    /// Resolves the profile root per operation. Deliberately dynamic rather
    /// than captured at init: `ProfileManager.profilesDir` has always been
    /// dynamic, and managers are sometimes constructed before a test sets
    /// `testProfilesRoot` (`SessionHost` builds one in `init`) yet used after.
    private let rootProvider: @Sendable () -> String

    /// In-memory roster, seeded once per root.
    private var cache: [String: Profile] = [:]

    /// The root `cache` was seeded from. A changed root forces a reseed, so a
    /// live store can never serve one root's records under another root's
    /// paths.
    private var seededRoot: String?

    /// A store pinned to `root` (tests, fixtures).
    public init(root: String) {
        self.rootProvider = { root }
    }

    /// A store following the process profile root.
    public init() {
        self.rootProvider = { ProfileManager.profilesDir }
    }

    /// The root this store is currently writing to.
    private var root: String { rootProvider() }

    // MARK: - ProfileStore

    /// Every record, newest first. Reads overlay `config.json`, so a
    /// hand-edited authoritative record is what the caller sees.
    public func list() async throws -> [Profile] {
        seedIfNeeded()
        let root = self.root
        return cache.values
            .map { Self.overlayWithConfig($0, root: root) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The record for `name`, or `nil`.
    public func get(_ name: ProfileName) async throws -> Profile? {
        seedIfNeeded()
        guard let cached = cache[name.rawValue] else { return nil }
        // The cache may be newer than the index but older than a hand-edited
        // config.json; always overlay the authoritative config record.
        return Self.overlayWithConfig(cached, root: root)
    }

    /// Create-or-replace `profile`. No `await` between the config write and
    /// the index write, so the actor cannot interleave a competing mutation.
    public func put(_ profile: Profile) async throws {
        seedIfNeeded()
        let root = self.root
        // Keep the profile directory self-contained in every mode (reference
        // profile distributions rely on `profiles/<name>/config.json`).
        try Self.writeConfig(profile, root: root)
        var index = cache
        index[profile.name] = profile
        try Self.writeIndex(index, root: root)
        cache = index
    }

    /// Remove `name` from the index and delete its profile directory.
    /// Idempotent: an unknown name is a no-op, not an error.
    public func delete(_ name: ProfileName) async throws {
        seedIfNeeded()
        let root = self.root
        var index = cache
        guard index.removeValue(forKey: name.rawValue) != nil else {
            return
        }
        try Self.writeIndex(index, root: root)
        cache = index

        let dir = URL(fileURLWithPath: root).appendingPathComponent(name.rawValue, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Seeding

    /// Seed the cache from `index.json`, creating the `default` profile the
    /// first time this root is seen (today: `ProfileManager.seedCache`).
    private func seedIfNeeded() {
        let root = self.root
        guard seededRoot != root else { return }

        var loaded = Self.loadIndex(root: root)

        // Ensure the "default" profile always exists.
        if loaded["default"] == nil {
            let defaultProfile = Profile(
                name: "default",
                title: "ARC Agent",
                description: "The primary agent."
            )
            loaded["default"] = defaultProfile
            // Best-effort, as before: a read must not fail because the
            // bootstrap record could not be written.
            try? Self.writeConfig(defaultProfile, root: root)
            try? Self.writeIndex(loaded, root: root)
        }

        cache = loaded
        seededRoot = root
    }

    // MARK: - File format

    /// Load and overlay `index.json` under `root`. A missing or unparseable
    /// index is an empty roster, exactly as before.
    static func loadIndex(root: String) -> [String: Profile] {
        let path = URL(fileURLWithPath: root).appendingPathComponent("index.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let index = try? JSONDecoder().decode([String: Profile].self, from: data) else {
            return [:]
        }
        // The index is a list cache; `profiles/<name>/config.json` is the
        // authoritative full record (users may edit it directly). Overlay so
        // hand-edited values take effect even when the index entry is stale.
        return index.mapValues { overlayWithConfig($0, root: root) }
    }

    /// Write `index` to `<root>/index.json`, atomically.
    static func writeIndex(_ index: [String: Profile], root: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: root),
            withIntermediateDirectories: true
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(index)
        let path = URL(fileURLWithPath: root).appendingPathComponent("index.json").path
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Write `profile` to `<root>/<name>/config.json`, atomically.
    static func writeConfig(_ profile: Profile, root: String) throws {
        let dir = URL(fileURLWithPath: root).appendingPathComponent(profile.name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(profile)
        try data.write(to: dir.appendingPathComponent("config.json"), options: .atomic)
    }

    /// Merge the non-nil fields of `profiles/<name>/config.json` over `base`
    /// (the index/cache entry), so hand-edited config.json values win.
    static func overlayWithConfig(_ base: Profile, root: String) -> Profile {
        let cfgPath = URL(fileURLWithPath: root)
            .appendingPathComponent(base.name, isDirectory: true)
            .appendingPathComponent("config.json")
            .path
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
              let full = try? JSONDecoder().decode(Profile.self, from: configData) else {
            return base
        }
        var merged = base
        merged.title = full.title
        merged.description = full.description
        if let v = full.model { merged.model = v }
        if let v = full.provider { merged.provider = v }
        if let v = full.baseURL { merged.baseURL = v }
        if let v = full.context { merged.context = v }
        if let v = full.contextSkills { merged.contextSkills = v }
        if let v = full.enabledToolsets { merged.enabledToolsets = v }
        if let v = full.disabledToolsets { merged.disabledToolsets = v }
        if let v = full.soulMD { merged.soulMD = v }
        merged.hasCustomKey = merged.hasCustomKey || full.hasCustomKey
        return merged
    }
}
