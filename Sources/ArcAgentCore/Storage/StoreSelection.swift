import Foundation

/// Process-wide Tessera availability decision.
///
/// Mirrors the gate the gateway/CLI/WebUI already apply to sessions + memory
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
    /// forced/cached decision when made; otherwise configures + health-checks.
    public func isTesseraActive() async -> Bool {
        if let forced { return forced }
        if let cached { return cached }
        let conn = TesseraConnection.shared
        // Already proven and live in this process (e.g. by session store
        // selection at startup) — no destructive re-probe.
        if await conn.isStartedNow {
            cached = true
            return true
        }
        guard let tessera = loadConfig().tessera else {
            cached = false
            return false
        }
        await conn.configure(tessera)
        let ok = await conn.healthCheck()
        cached = ok
        return ok
    }
}

/// A ``CronStore`` that resolves to ``TesseraCronStore`` when Tessera is
/// active and to ``FileCronStore`` otherwise — lazily, on first use, so the
/// synchronous construction paths (gateway, CLI) need no async setup.
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
