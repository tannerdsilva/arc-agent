import Foundation

/// A scheduled cron job.
///
/// Jobs can be one-shot (ISO timestamp) or recurring (cron expression or
/// human-readable interval like "30m", "every 2h").
public struct CronJob: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier.
    public let id: String
    /// Human-readable name.
    public var name: String
    /// The schedule expression (e.g. "30m", "every 2h", "0 9 * * *", ISO timestamp).
    public var schedule: String
    /// The prompt or task to execute.
    public var prompt: String
    /// Whether the job is active.
    public var isActive: Bool
    /// When the job was created.
    public let createdAt: Date
    /// When the job last ran.
    public var lastRunAt: Date?
    /// When the job should run next.
    public var nextRunAt: Date?
    /// Number of times the job has run.
    public var runCount: Int
    /// Last output from the job.
    public var lastOutput: String?
    /// Status of the last run: "ok" | "error" | "timeout". Part of the
    /// per-run job payload so the tessera event stream doubles as history.
    public var lastStatus: String?
    /// When the last run started.
    public var lastStartedAt: Date?
    /// When the last run finished.
    public var lastFinishedAt: Date?
    /// The failure message when `lastStatus` is "error".
    public var lastError: String?
    /// When the job was paused (``CronOps.pause``). Cleared on resume.
    public var pausedAt: Date?
    /// Why the job was paused (human or agent note). Cleared on resume.
    public var pausedReason: String?
    /// Run budget: the job self-retires after N runs (nil = unlimited).
    /// JSON key stays `"repeat"` (Hermes parity) even though the Swift
    /// name can't be the keyword — see ``CodingKeys``.
    public var repeatBudget: Int?
    /// Live countdown for ``repeatBudget``; persisted so a restart can't
    /// resurrect an exhausted budget. Nil = no budget / budget not armed.
    public var runsRemaining: Int?
    /// Reset the job's persistent session every N runs (nil = never).
    /// The reset happens BETWEEN firings — a job's in-flight turn is
    /// never cut; the next firing starts in a fresh session.
    public var resetEveryRuns: Int?
    /// Runs completed since the last session reset. Persisted with the
    /// per-run save, so a daemon restart mid-bucket does not zero the
    /// count (a stateless counter would silently reset the bucket).
    public var runsSinceReset: Int?
    /// One-shot signal: the NEXT firing must start in a fresh session.
    /// Set by the scheduler when the bucket crosses the threshold, read
    /// (and consumed) by the runner before it builds the session.
    public var needsSessionReset: Bool
    /// Shell line to run INSTEAD of the LLM (plan Phase 6.2). Non-nil
    /// bypasses the agent entirely: stdout = the run's output, empty
    /// stdout + exit 0 = silent, non-zero/timeout = alert. Vetted through
    /// the Security pipeline at job-creation time — a stored hardline
    /// script is rejected on save, never laundered later.
    public var script: String?
    /// The profile that created/wrote the job. Nil = manageable by anyone
    /// (covers web-UI- and CLI-created jobs; agent tools stamp their
    /// captured ``ToolContext``). Phase 6 scoping reads this.
    public var profile: String?
    /// Delivery target for run results: `"<platform>:<chatID>"`, e.g.
    /// `telegram:123456789`. One target in v1; nil or "none" = result
    /// stays in the job's own record (and the persistent session).
    public var deliver: String?
    /// The delivery failure from the last run, if any. A delivery failure
    /// does NOT fail the run — `lastStatus` reflects the agent run only.
    public var lastDeliveryError: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        schedule: String,
        prompt: String,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.isActive = isActive
        self.createdAt = Date()
        self.lastRunAt = nil
        self.nextRunAt = nil
        self.runCount = 0
        self.lastOutput = nil
        self.lastStatus = nil
        self.lastStartedAt = nil
        self.lastFinishedAt = nil
        self.lastError = nil
        self.pausedAt = nil
        self.pausedReason = nil
        self.repeatBudget = nil
        self.runsRemaining = nil
        self.resetEveryRuns = nil
        self.runsSinceReset = nil
        self.needsSessionReset = false
        self.script = nil
        self.profile = nil
        self.deliver = nil
        self.lastDeliveryError = nil
    }

    /// Field names on disk. `repeat` is a Swift keyword, so the budget is
    /// `repeatBudget` in code but `repeat` in JSON (Hermes parity).
    enum CodingKeys: String, CodingKey {
        case id, name, schedule, prompt
        case isActive
        case createdAt
        case nextRunAt, lastRunAt, lastStartedAt, lastFinishedAt
        case lastOutput, lastStatus, lastError, lastDeliveryError
        case runCount
        case pausedAt, pausedReason
        case repeatBudget = "repeat"
        case runsRemaining
        case resetEveryRuns, runsSinceReset, needsSessionReset
        case profile, deliver
        case script
    }
}

/// A store for cron jobs.
///
/// ``CronStore`` is a **protocol**. The default implementation is
/// ``FileCronStore`` (JSON files). A Tessera-backed implementation will
/// follow once the session/memory stores prove out.
// MARK: - Run result (runner → scheduler handoff)

/// What a job runner hands back to the scheduler. The runner owns side
/// effects (platform delivery); the scheduler owns persistence — one
/// `store.save(job)` stamps output, status AND delivery outcome together
/// (the single-save rule).
public struct CronRunResult: Sendable {
    /// The job's answer (the first response of its one-shot session).
    public let output: String
    /// Why delivery to `job.deliver` failed, if it did. Nil = delivered
    /// (or nothing to deliver). Never affects `lastStatus`.
    public let deliveryError: String?

    public init(output: String, deliveryError: String? = nil) {
        self.output = output
        self.deliveryError = deliveryError
    }
}

/// Parse a job's `deliver` field into a `ChatTarget`, or nil.
///
/// Grammar: `"none"`/nil → nil (no delivery); otherwise exactly one
/// `"<platform>:<chatID>"` — chatID may itself contain colons (Slack
/// thread suffixes), so the split keeps everything after the FIRST colon.
public func CronDeliveryTarget(jobDeliver: String?) -> ChatTarget? {
    guard let deliver = jobDeliver, deliver != "none" else { return nil }
    let parts = deliver.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return ChatTarget(platform: parts[0], chatID: parts[1])
}

// MARK: - Store + history (plan §2)

public protocol CronStore: Sendable {
    func save(_ job: CronJob) async throws
    func get(id: String) async throws -> CronJob?
    func delete(id: String) async throws
    func listActive() async throws -> [CronJob]
    func listAll() async throws -> [CronJob]
}

/// A file-based cron job store (JSON files under `~/.arc/cron/`).
///
/// Deliberately **stateless**: every read scans the directory and every write
/// touches the file, so several processes (the daemon's scheduler, the CLI,
/// `arc blueprint`, the web UI) all observe the same jobs with no per-instance
/// cache to go stale — a cache here made a job created through one store
/// instance invisible to another until restart. The job count is small and the
/// access pattern is a 30 s poll, so the scan is free.
public actor FileCronStore: CronStore {

    private let directory: URL

    /// The store root (`~/.arc/cron/`) — run history lives at
    /// `<root>/history/<jobID>/`. Nonisolated: the directory is immutable.
    public nonisolated var homeDirectory: URL { directory }

    public init(directory: URL? = nil) {
        let dir = directory ?? ArcHome.cron
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func save(_ job: CronJob) async throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(job)
        try data.write(to: directory.appendingPathComponent("\(job.id).json"), options: .atomic)
    }

    public func get(id: String) async throws -> CronJob? {
        let url = directory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              let job = try? JSONDecoder().decode(CronJob.self, from: data)
        else { return nil }
        return job
    }

    public func delete(id: String) async throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    public func listActive() async throws -> [CronJob] {
        try await listAll().filter { $0.isActive }
    }

    public func listAll() async throws -> [CronJob] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { data in
                    try? JSONDecoder().decode(CronJob.self, from: data)
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
