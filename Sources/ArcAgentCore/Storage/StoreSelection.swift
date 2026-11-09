import Foundation
import Logging

/// The storage mediums a configuration can select.
public enum StorageMedium: String, Sendable, Equatable, CaseIterable {
    /// Local files under `~/.arc` (sessions, memories, profiles).
    case file
    /// The Tessera relay named by the config's `tessera` block.
    case tessera
}

/// The one storage-medium decision, resolved from a configuration.
///
/// Before this type the same question had two answers: `config.tessera`
/// *presence* decided what the daemon and the CLI used, while the web UI's
/// `settings.activeStorage` decided what the UI used — so a user who picked
/// file storage in Settings kept getting Tessera sessions from Telegram.
/// Every surface now resolves through here, from `storage.active`.
public struct StoreSelection: Sendable, Equatable {

    /// The medium this configuration selects.
    public let backend: StorageMedium

    /// The tunnel to configure in ``StorageMedium/tessera`` mode; nil for files.
    public let tessera: TesseraConfig?

    /// A policy that named Tessera but no `tessera` block exists in the file:
    /// the decision fell back to files, and said so in the log.
    public let fellBackFromPolicy: Bool

    public init(
        backend: StorageMedium,
        tessera: TesseraConfig? = nil,
        fellBackFromPolicy: Bool = false
    ) {
        self.backend = backend
        self.tessera = tessera
        self.fellBackFromPolicy = fellBackFromPolicy
    }

    /// Local files, whatever the config carries (the `--tessera-off` override).
    public static let file = StoreSelection(backend: .file)

    /// Resolve one configuration into the process's storage decision.
    ///
    /// Decision table:
    /// - `storage.active == "file"` → files, even when a `tessera` block exists;
    /// - `storage.active == "tessera"` → that block, else files + a log;
    /// - key absent → the legacy inference (a `tessera` block means Tessera);
    /// - any other spelling → files + a log, never a guess at a remote backend.
    public static func resolve(_ config: ArcConfig) -> StoreSelection {
        let declared = config.storage.active?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch declared?.lowercased() {
        case StorageMedium.file.rawValue?:
            return .file

        case StorageMedium.tessera.rawValue?:
            guard let tessera = config.tessera else {
                Logger(label: "com.arc-agent.storage").warning(
                    "storage.active is \"tessera\" but config.json has no tessera block; using file storage")
                return StoreSelection(backend: .file, fellBackFromPolicy: true)
            }
            return StoreSelection(backend: .tessera, tessera: tessera)

        case nil:
            // Legacy inference: the `tessera` block was the switch before
            // `storage.active` existed, so an unwritten config keeps its medium.
            guard let tessera = config.tessera else { return .file }
            return StoreSelection(backend: .tessera, tessera: tessera)

        default:
            Logger(label: "com.arc-agent.storage").warning(
                "storage.active \"\(declared ?? "")\" is not \"file\" or \"tessera\"; using file storage")
            return StoreSelection(backend: .file, fellBackFromPolicy: true)
        }
    }
}

extension TesseraConfig {
    /// The endpoint this block names — everything a storage picker row shows.
    ///
    /// The client private key is deliberately absent: `saveConfig` splits it
    /// into `.env`, so the block in `config.json` and an equivalent saved
    /// connection differ on that field alone. Matching a resolved medium back
    /// to the connection that names it must not depend on a secret that may
    /// or may not be in the file.
    public var endpointIdentity: String {
        "\(serverIP):\(serverPort)|\(application)|\(serverPublicKey)"
    }
}

/// Process-wide Tessera availability decision.
///
/// Mirrors the gate the daemon/CLI/WebUI already apply to sessions + memory
/// (`config.tessera` present **and** reachable → Tessera stores; otherwise
/// file fallback). The result is cached per process so cron/goal stores
/// never probe repeatedly (a probe ends with a connection ``shutdown()``).
public actor TesseraAvailability {

    public static let shared = TesseraAvailability()

    private var cached: Bool?
    private var forced: Bool?

    /// Test seam (mirrors ``ProfileManager.testProfilesRoot``): force the
    /// decision, bypassing config reads and network probes. `nil` restores
    /// automatic resolution.
    public func force(_ active: Bool?) {
        forced = active
        cached = nil
    }

    /// Whether Tessera storage should be used for this process. Returns the
    /// forced/cached decision when made; otherwise resolves the medium from
    /// config and health-checks the relay.
    public func isTesseraActive() async -> Bool {
        if let forced { return forced }
        if let cached { return cached }
        // The policy decides first: a process that selected files must not
        // hand a live tunnel to the cron/goal stores just because a previous
        // runtime left `TesseraConnection` started.
        let selection = StoreSelection.resolve(loadConfig())
        guard selection.backend == .tessera, let tessera = selection.tessera else {
            cached = false
            return false
        }
        let conn = TesseraConnection.shared
        // Already proven and live in this process (e.g. by session store
        // selection at startup) — no destructive re-probe.
        if await conn.isStartedNow {
            cached = true
            return true
        }
        await conn.configure(tessera)
        let ok = await conn.healthCheck()
        cached = ok
        return ok
    }
}

/// A ``CronStore`` that resolves to ``TesseraCronStore`` when Tessera is
/// active and to ``FileCronStore`` otherwise — lazily, on first use, so the
/// synchronous construction paths (daemon, CLI) need no async setup.
///
/// Like ``FileCronStore``, this is cache-first; the underlying store is
/// chosen once per process.
public actor RuntimeCronStore: CronStore {

    private var store: (any CronStore)?

    public init() {}

    private func resolve() async -> any CronStore {
        if let store { return store }
        let tessera = await TesseraAvailability.shared.isTesseraActive()
        let chosen: any CronStore = tessera ? TesseraCronStore() : FileCronStore()
        store = chosen
        return chosen
    }

    public func save(_ job: CronJob) async throws {
        try await resolve().save(job)
    }

    public func get(id: String) async throws -> CronJob? {
        try await resolve().get(id: id)
    }

    public func delete(id: String) async throws {
        try await resolve().delete(id: id)
    }

    public func listActive() async throws -> [CronJob] {
        try await resolve().listActive()
    }

    public func listAll() async throws -> [CronJob] {
        try await resolve().listAll()
    }
}

/// A ``CronRunHistory`` resolving to ``TesseraCronRunHistory`` when Tessera
/// is active and to ``FileCronRunHistory`` otherwise — the same lazy gate as
/// ``RuntimeCronStore``. Every surface resolves history through this actor
/// so jobs and history can never disagree about medium.
public actor RuntimeCronRunHistory: CronRunHistory {

    private var history: (any CronRunHistory)?

    public init() {}

    private func resolve() async -> any CronRunHistory {
        if let history { return history }
        let tessera = await TesseraAvailability.shared.isTesseraActive()
        let chosen: any CronRunHistory = tessera ? TesseraCronRunHistory() : FileCronRunHistory()
        history = chosen
        return chosen
    }

    public func record(_ run: CronRunRecord, jobID: String) async throws {
        try await resolve().record(run, jobID: jobID)
    }

    public func listRuns(jobID: String, limit: Int) async throws -> [CronRunRecord] {
        try await resolve().listRuns(jobID: jobID, limit: limit)
    }

    public func prune(jobID: String, keep: Int) async throws {
        try await resolve().prune(jobID: jobID, keep: keep)
    }
}
