import Foundation

/// A process-wide keyed gate so one cron job never runs twice concurrently.
///
/// Two entry points can fire a job: the ``CronScheduler`` tick and the web
/// UI's manual "Run now". Both check in here before spawning a turn — the
/// second caller skips instead of double-firing (which would duplicate the
/// turn in the job's chat AND duplicate its run record).
public actor CronRunGate {
    public static let shared = CronRunGate()

    private var running: Set<String> = []

    public init() {}

    /// Returns false when the job is already running somewhere in this
    /// process; true (and holds the slot) otherwise.
    public func tryAcquire(_ jobID: String) -> Bool {
        guard !running.contains(jobID) else { return false }
        running.insert(jobID)
        return true
    }

    public func release(_ jobID: String) {
        running.remove(jobID)
    }

    /// Run `body` under the job's slot. Returns nil when the job was
    /// already running (body never executed).
    public func withJob<T>(_ jobID: String, _ body: @Sendable () async throws -> T) async throws -> T? {
        guard tryAcquire(jobID) else { return nil }
        do {
            let value = try await body()
            release(jobID)
            return value
        } catch {
            release(jobID)
            throw error
        }
    }
}
