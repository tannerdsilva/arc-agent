import Foundation

// MARK: - Durable run history (plan Phase 2, Option C — medium-uniform)
//
// One attempt = one record. In file mode a JSON file under
// `~/.arc/cron/history/<jobID>/`; in tessera mode the per-run kind-3005
// job event **is** the record (see ``TesseraCronRunHistory``): the
// scheduler's existing re-save carries status/timestamps, the read path
// decodes the whole per-job event stream. Retention is a read-time limit
// in both media — listing never deletes; file-mode `prune` is the only
// destructive operation and only touches files.

/// One durable attempt of a cron job.
public struct CronRunRecord: Sendable, Codable, Equatable {
    /// The job this attempt belongs to.
    public let jobID: String
    /// When the runner picked the job up.
    public let startedAt: Date
    /// When the runner returned. Nil while a run is in flight (and for
    /// records derived from legacy job payloads that never stamped it).
    public var finishedAt: Date?
    /// "ok" | "error" | "timeout". Nil for pre-history job events.
    public var status: String?
    /// The run's output, capped at 4 KB like `lastOutput`.
    public var output: String
    /// The failure message when status is "error".
    public var error: String?

    public init(jobID: String, startedAt: Date, finishedAt: Date? = nil, status: String? = nil, output: String, error: String? = nil) {
        self.jobID = jobID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.output = output
        self.error = error
    }
}

/// Per-attempt history for cron jobs. Deliberately **not** part of
/// ``CronStore`` — existing conformances stay untouched, and the two
/// concerns have different shapes (jobs are documents; history is a log).
public protocol CronRunHistory: Sendable {
    /// Append one attempt. In tessera mode this is a no-op: the record
    /// arrives through the scheduler's single per-run `save(job)`.
    func record(_ run: CronRunRecord, jobID: String) async throws
    /// Newest-first runs for a job, at most `limit` of them. Never deletes.
    func listRuns(jobID: String, limit: Int) async throws -> [CronRunRecord]
    /// File mode only: delete record FILES beyond the newest `keep`.
    /// No-op for the tessera backend (events are append-only).
    func prune(jobID: String, keep: Int) async throws
}

/// The 4 KB output cap, shared with `lastOutput`.
public let cronOutputCap = 4_000

/// A ``CronRunHistory`` writing one JSON file per attempt under
/// `<directory>/<jobID>/<timestamp>.json`. Deliberately stateless like
/// ``FileCronStore``: reads scan the directory, so the CLI, the scheduler
/// and the web UI observe the same records with no cache to go stale.
public actor FileCronRunHistory: CronRunHistory {

    private let directory: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? ArcHome.cron.appendingPathComponent("history", isDirectory: true)
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - CronRunHistory

    public func record(_ run: CronRunRecord, jobID: String) async throws {
        let jobDir = directory.appendingPathComponent(jobID, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        // Filename carries the start time (ms, zero-padded so lexicographic
        // order is chronological) plus a short uuid suffix for same-ms runs.
        let ms = Int(run.startedAt.timeIntervalSince1970 * 1_000)
        let url = jobDir.appendingPathComponent("\(String(format: "%015d", ms))-\(UUID().uuidString.prefix(8)).json")
        try enc.encode(run).write(to: url, options: .atomic)
    }

    public func listRuns(jobID: String, limit: Int) async throws -> [CronRunRecord] {
        Self.runs(from: Self.files(jobID: jobID, in: directory), limit: limit)
    }

    public func prune(jobID: String, keep: Int) async throws {
        let files = Self.files(jobID: jobID, in: directory)
        guard files.count > keep else { return }
        // Lexicographic sort == chronological (ms timestamp prefix).
        for url in files.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(files.count - keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers (exposed for unit tests)

    /// Record files for one job, newest-last (lexicographic on the
    /// timestamp-prefixed name). Corrupted files are skipped, not thrown.
    static func files(jobID: String, in directory: URL) -> [URL] {
        let jobDir = directory.appendingPathComponent(jobID, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: jobDir.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { jobDir.appendingPathComponent($0) }
    }

    /// Decode record files, newest-first. A corrupted record is skipped —
    /// one bad file must not hide the rest of the job's history.
    static func runs(from files: [URL], limit: Int) -> [CronRunRecord] {
        files.reversed().compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let run = try? JSONDecoder().decode(CronRunRecord.self, from: data)
            else { return nil }
            return run
        }
        .prefix(limit)
        .map { $0 }
    }
}
