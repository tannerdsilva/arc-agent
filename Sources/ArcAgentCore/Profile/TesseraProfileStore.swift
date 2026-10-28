import Foundation

// MARK: - TesseraProfileStore

/// The Tessera-backed roster: one kind-3004 event per profile revision,
/// dTag `arc/p/<name>/<seq>` (highest seq wins), with the JSON index as the
/// degraded path.
///
/// This is `ProfileManager`'s Tessera branch extracted verbatim — the sequence
/// hand-out, the latest-per-name fold, the `isUnavailable` fallbacks, and the
/// `config.json` write that every mode performs are all unchanged. The dTag
/// scheme is fixed: on-disk history already carries it (GROUNDZERO §8).
///
/// **One writer.** Reads and writes serialize on this actor; the connection is
/// the process-wide ``TesseraConnection`` shared with sessions and memory, and
/// is not owned here.
///
/// The file fallback is uncached on purpose: it reads and writes `index.json`
/// through ``FileProfileStore``'s static helpers so this store never becomes a
/// second index cache. It only runs when Tessera is unconfigured or the tunnel
/// is unavailable.
public actor TesseraProfileStore: ProfileStore {

    /// Resolves the profile root per operation (see ``FileProfileStore`` for
    /// why this is dynamic rather than captured).
    private let rootProvider: @Sendable () -> String

    /// Latest record per name, seeded once per root.
    private var cache: [String: Profile] = [:]
    private var seededRoot: String?
    private var cacheSeeded = false

    /// A store pinned to `root` (tests, fixtures).
    public init(root: String) {
        self.rootProvider = { root }
    }

    /// A store following the process profile root.
    public init() {
        self.rootProvider = { ProfileManager.profilesDir }
    }

    /// The process's roster writer.
    ///
    /// One instance, because the point of the port is one writer: shims and
    /// services that all construct their own store would each keep a private
    /// cache over the same `index.json` and reintroduce exactly the loss this
    /// store exists to prevent. Root changes (`testProfilesRoot`) are handled
    /// by the reseed guard, so a shared instance stays correct in tests.
    public static let shared = TesseraProfileStore()

    private var root: String { rootProvider() }

    /// Whether roster mutations go to Tessera. A `testProfilesRoot` override
    /// means the caller is hermetic: always the JSON index under that root,
    /// never the process-wide store (which would leak profiles across
    /// isolated test roots).
    private func usesTessera() async -> Bool {
        guard ProfileManager.testProfilesRoot == nil else { return false }
        return await TesseraConnection.shared.isConfigured
    }

    // MARK: - ProfileStore

    public func list() async throws -> [Profile] {
        try await seedIfNeeded()
        let root = self.root
        return cache.values
            .map { FileProfileStore.overlayWithConfig($0, root: root) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func get(_ name: ProfileName) async throws -> Profile? {
        try await seedIfNeeded()
        guard let cached = cache[name.rawValue] else { return nil }
        return FileProfileStore.overlayWithConfig(cached, root: root)
    }

    public func put(_ profile: Profile) async throws {
        try await seedIfNeeded()
        try await persist(profile, root: root)
        cache[profile.name] = profile
    }

    public func delete(_ name: ProfileName) async throws {
        try await seedIfNeeded()
        let root = self.root

        // Remove from the profile index (Tessera or JSON file).
        if await usesTessera() {
            do {
                try await TesseraConnection.shared.deleteAll(
                    dTagPrefix: "arc/p/\(name.rawValue)/",
                    kind: TesseraConnection.profileKind
                )
            } catch let error as TesseraStoreError where error.isUnavailable {
                var index = FileProfileStore.loadIndex(root: root)
                index.removeValue(forKey: name.rawValue)
                try FileProfileStore.writeIndex(index, root: root)
            }
        } else {
            var index = FileProfileStore.loadIndex(root: root)
            index.removeValue(forKey: name.rawValue)
            try FileProfileStore.writeIndex(index, root: root)
        }

        // Remove filesystem data.
        let profileDir = URL(fileURLWithPath: root).appendingPathComponent(name.rawValue, isDirectory: true)
        try? FileManager.default.removeItem(at: profileDir)

        cache.removeValue(forKey: name.rawValue)
    }

    // MARK: - Private

    /// Seed the cache from Tessera events or the JSON index, creating the
    /// `default` profile on first access (today: `ProfileManager.seedCache`).
    private func seedIfNeeded() async throws {
        let root = self.root
        guard !cacheSeeded || seededRoot != root else { return }

        do {
            var loaded: [String: Profile] = [:]
            if await usesTessera() {
                do {
                    loaded = try await loadProfilesFromTessera()
                } catch let error as TesseraStoreError where error.isUnavailable {
                    // Relay/tunnel unavailable mid-run (same degradation as the
                    // boot-time file fallback): keep profiles functional from
                    // the JSON index.
                    loaded = FileProfileStore.loadIndex(root: root)
                }
            } else {
                loaded = FileProfileStore.loadIndex(root: root)
            }

            // Ensure the "default" profile always exists.
            if loaded["default"] == nil {
                let defaultProfile = Profile(
                    name: "default",
                    title: "ARC Agent",
                    description: "The primary agent."
                )
                loaded["default"] = defaultProfile
                _ = try? await persist(defaultProfile, root: root)
            }

            cache = loaded
            seededRoot = root
            cacheSeeded = true
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

    /// Persist a profile to Tessera (when configured) or the JSON index.
    /// When the tunnel is configured but unavailable, the JSON index takes
    /// over — the write must not hang or fail just because the relay is down.
    private func persist(_ profile: Profile, root: String) async throws {
        // Keep the profile directory self-contained in every mode (reference
        // profile distributions rely on `profiles/<name>/config.json`).
        try FileProfileStore.writeConfig(profile, root: root)
        if await usesTessera() {
            do {
                let conn = TesseraConnection.shared
                try await conn.ensureStarted()
                let seq = await conn.takeSequence()
                let content = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
                try await conn.publish(
                    kind: TesseraConnection.profileKind,
                    dTagValue: "arc/p/\(profile.name)/\(seq)",
                    content: content
                )
                return
            } catch let error as TesseraStoreError where error.isUnavailable {
                // Tunnel unavailable: fall through to the JSON index.
            }
        }
        var index = FileProfileStore.loadIndex(root: root)
        index[profile.name] = profile
        try FileProfileStore.writeIndex(index, root: root)
    }
}
