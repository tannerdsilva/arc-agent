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
    }
}

/// A store for cron jobs.
///
/// ``CronStore`` is a **protocol**. The default implementation is
/// ``FileCronStore`` (JSON files). A Tessera-backed implementation will
/// follow once the session/memory stores prove out.
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

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/cron")
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func save(_ job: CronJob) async throws {
        let data = try JSONEncoder().encode(job)
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
