import Foundation
import Logging

/// The single door to `config.json`.
///
/// Every process that reads or writes configuration goes through one store:
/// the web UI's settings page, the CLI's config commands, and the daemon's
/// per-session agents. The store owns three guarantees that were previously
/// spread across 35 `loadConfig()` sites and 16 `saveConfig()` sites:
///
/// 1. **One write path.** ``mutate(_:)`` is the only way configuration
///    changes. It takes the declared config, applies the edit, writes
///    atomically, decodes the bytes it wrote, and only then publishes.
/// 2. **No silent clobber.** If the file on disk cannot be decoded, the store
///    records the failure and *refuses* writes. The old shape read a corrupt
///    file as "defaults", so the next settings toggle wrote a full default
///    config over the user's file.
/// 3. **Declared vs resolved.** ``declared`` is what the file says (what a
///    write edits); ``resolved`` is what this process runs with (file +
///    environment). The UI writes declared and renders resolved, so an env
///    override is never baked back into the file.
///
/// `~/.arc/config.json` is resolved through ``ArcHome``, so a second instance
/// (`ARC_HOME=/srv/arc-b`) reads and writes its own file.
public actor ConfigurationStore {

    /// One consistent view of the configuration at a point in time.
    public struct Snapshot: Sendable, Equatable {
        /// The file's contents, before environment overrides.
        public let declared: ArcConfig
        /// The configuration this process runs with (declared + environment).
        public let resolved: ArcConfig
        /// The file the store reads and writes.
        public let url: URL

        public init(declared: ArcConfig, resolved: ArcConfig, url: URL) {
            self.declared = declared
            self.resolved = resolved
            self.url = url
        }
    }

    /// The process-wide store.
    public static let shared = ConfigurationStore()

    private let url: URL
    private let environment: [String: String]
    private var snapshotValue: Snapshot
    /// Non-nil when the file exists but cannot be decoded. Writes are refused
    /// until the file is fixed (or removed), so a bad edit can never be
    /// replaced by compiled defaults.
    private var loadFailure: ConfigError?
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    /// - Parameters:
    ///   - url: the config file. Defaults to ``ArcHome/config``.
    ///   - environment: the environment overrides are read from. Injected so
    ///     tests never depend on the ambient process environment.
    public init(url: URL = ArcHome.config, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.url = url
        self.environment = environment
        var declared = ArcConfig()
        var failure: ConfigError?
        do {
            declared = try ConfigurationStore.readDeclared(url)
        } catch let error as ConfigError {
            failure = error
            // keep the log line the old loader emitted: a silent discard here
            // means every model/provider choice is ignored.
            Logger(label: "com.arc-agent.config").error(
                "Failed to parse \(url.path); configuration is read-only until it is fixed: \(error)"
            )
        } catch {
            failure = .parseError(String(describing: error))
        }
        self.loadFailure = failure
        self.snapshotValue = Snapshot(
            declared: declared,
            resolved: ConfigurationStore.resolve(declared, environment: environment, url: url),
            url: url
        )
    }

    // MARK: - Reading

    /// The current snapshot.
    public func snapshot() -> Snapshot { snapshotValue }

    /// The declaration (file contents, no environment overrides).
    public func declared() -> ArcConfig { snapshotValue.declared }

    /// The configuration this process runs with.
    public func resolved() -> ArcConfig { snapshotValue.resolved }

    /// The decode failure that makes this store read-only, if any.
    public func failure() -> ConfigError? { loadFailure }

    /// Re-read the file (an external `arc config` edit, a hand edit).
    ///
    /// Returns the published snapshot. A file that no longer decodes marks the
    /// store read-only instead of discarding the last good declaration.
    @discardableResult
    public func reload() -> Snapshot {
        do {
            let declared = try ConfigurationStore.readDeclared(url)
            loadFailure = nil
            snapshotValue = Snapshot(
                declared: declared,
                resolved: ConfigurationStore.resolve(declared, environment: environment, url: url),
                url: url
            )
        } catch let error as ConfigError {
            loadFailure = error
        } catch {
            loadFailure = .parseError(String(describing: error))
        }
        publish(snapshotValue)
        return snapshotValue
    }

    // MARK: - Writing

    /// Apply one edit and persist it. The only write path.
    ///
    /// - Parameter body: the mutation, applied to the declared config.
    /// - Throws: ``ConfigError`` when the file is unreadable (see
    ///   ``failure()``) or when the write/round-trip fails. On a throw the
    ///   in-memory snapshot is unchanged and nothing was published.
    @discardableResult
    public func mutate(_ body: @Sendable (inout ArcConfig) throws -> Void) throws -> Snapshot {
        if let loadFailure { throw loadFailure }
        var next = snapshotValue.declared
        try body(&next)
        // refuse a no-op write: nothing changed, nothing published.
        guard next != snapshotValue.declared else { return snapshotValue }
        try ConfigurationStore.write(next, to: url)
        // prove the bytes we wrote decode back to what we meant before any
        // reader sees the new value.
        let verified = try ConfigurationStore.readDeclared(url)
        snapshotValue = Snapshot(
            declared: verified,
            resolved: ConfigurationStore.resolve(verified, environment: environment, url: url),
            url: url
        )
        publish(snapshotValue)
        return snapshotValue
    }

    // MARK: - Observation

    /// A stream of every snapshot this store publishes.
    ///
    /// The stream finishes when its consumer cancels or the continuation is
    /// dropped; a subscriber never keeps the store alive.
    public func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func publish(_ snapshot: Snapshot) {
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    // MARK: - Pure file helpers (shared with `loadConfig`)

    /// Read and decode the declared configuration.
    ///
    /// A missing file is an empty declaration (compiled defaults); a file that
    /// exists but does not decode is a ``ConfigError/parseError`` — never a
    /// silent fall back to defaults.
    public static func readDeclared(_ url: URL) throws -> ArcConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return ArcConfig() }
        do {
            return try JSONDecoder().decode(ArcConfig.self, from: try Data(contentsOf: url))
        } catch {
            throw ConfigError.parseError("\(url.path): \(error)")
        }
    }

    /// Write the declared configuration, with secrets split into `.env`.
    public static func write(_ config: ArcConfig, to url: URL) throws {
        try saveConfig(config, to: url)
    }

    /// Apply environment overrides to a declared configuration.
    public static func resolve(
        _ config: ArcConfig,
        environment: [String: String],
        url: URL
    ) -> ArcConfig {
        let dotenv = loadDotEnv(url.deletingLastPathComponent().appendingPathComponent(".env"))
        return applyEnvironmentOverrides(config, environment: environment, dotenv: dotenv)
    }
}
