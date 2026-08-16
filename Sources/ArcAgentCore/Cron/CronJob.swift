import Foundation

/// A scheduled cron job.
///
/// Jobs can be one-shot (ISO timestamp) or recurring (cron expression or
/// human-readable interval like "30m", "every 2h").
public struct CronJob: Sendable, Codable, Identifiable {
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
/// ``FileCronStore`` (JSON files). An LMDB-backed implementation will
/// replace it once QuickLMDB is added.
public protocol CronStore: Sendable {
    func save(_ job: CronJob) async throws
    func get(id: String) async throws -> CronJob?
    func delete(id: String) async throws
    func listActive() async throws -> [CronJob]
    func listAll() async throws -> [CronJob]
}

/// A file-based cron job store.
public actor FileCronStore: CronStore {

    private let directory: URL
    private var cache: [String: CronJob] = [:]

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/cron")
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func save(_ job: CronJob) async throws {
        cache[job.id] = job
        let data = try JSONEncoder().encode(job)
        try data.write(to: directory.appendingPathComponent("\(job.id).json"), options: .atomic)
    }

    public func get(id: String) async throws -> CronJob? {
        if let cached = cache[id] { return cached }
        let url = directory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              let job = try? JSONDecoder().decode(CronJob.self, from: data)
        else { return nil }
        cache[id] = job
        return job
    }

    public func delete(id: String) async throws {
        cache[id] = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    public func listActive() async throws -> [CronJob] {
        try await listAll().filter { $0.isActive }
    }

    public func listAll() async throws -> [CronJob] {
        if cache.isEmpty {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let job = try? JSONDecoder().decode(CronJob.self, from: data) {
                    cache[job.id] = job
                }
            }
        }
        return Array(cache.values).sorted { $0.createdAt < $1.createdAt }
    }
}
