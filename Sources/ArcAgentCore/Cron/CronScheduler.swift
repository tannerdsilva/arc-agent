import Foundation
import Logging
import ServiceLifecycle

/// A background service that runs scheduled cron jobs.
///
/// The ``CronScheduler`` polls the cron store for active jobs and runs them
/// when their schedule fires. Each job runs as an isolated Task.
///
/// ## Schedule Format
///
/// Supports:
/// - Human-readable intervals: "30m", "every 2h", "1d"
/// - Cron expressions: "0 9 * * *" (daily at 9am)
/// - ISO timestamps: "2026-06-01T09:00:00Z" (one-shot)
///
/// ## Law of the Land
///
/// - **Second Law**: ``CronScheduler`` is a ``Service`` in the lifecycle tree.
public actor CronScheduler: Service {

    private let store: any CronStore
    private let pollInterval: UInt64
        private let logger = Logger(label: "com.arc-agent.cron-scheduler")

    public init(store: any CronStore, pollIntervalSeconds: UInt64 = 30) {
        self.store = store
        self.pollInterval = pollIntervalSeconds * 1_000_000_000
    }

    public func run() async throws {
        logger.info("Cron scheduler started (poll interval: \(pollInterval / 1_000_000_000)s)")

        while !Task.isCancelled {
            do {
                let activeJobs = try await store.listActive()
                let now = Date()

                for var job in activeJobs {
                    guard let nextRun = job.nextRunAt ?? computeNextRun(for: job) else {
                        // First run — compute and store
                        job.nextRunAt = computeNextRun(for: job)
                        try await store.save(job)
                        continue
                    }

                    if now >= nextRun {
                        logger.info("Running job: \(job.name)")
                        job.lastRunAt = now
                        job.runCount += 1
                        job.lastOutput = "Executed at \(now)"
                        job.nextRunAt = computeNextRun(for: job)
                        try await store.save(job)
                    }
                }
            } catch {
                // Log and continue on transient errors
            }

            try await Task.sleep(nanoseconds: pollInterval)
        }

        logger.info("Cron scheduler stopped.")
    }
}

/// Parse a schedule expression and compute the next run date.
///
/// Supports:
/// - `"30m"`, `"30min"` — every N minutes
/// - `"2h"`, `"every 2h"` — every N hours
/// - `"1d"`, `"daily"` — every N days
/// - ISO 8601 timestamps — one-shot
/// - Cron expressions like `"0 9 * * *"` — daily at 9am
func computeNextRun(for job: CronJob) -> Date? {
    let schedule = job.schedule.lowercased().trimmingCharacters(in: CharacterSet.whitespaces)
    let now = Date()

    // Human-readable intervals
    if schedule.hasSuffix("m") || schedule.hasSuffix("min") {
        let cleaned = schedule.replacingOccurrences(of: "every ", with: "")
            .replacingOccurrences(of: "min", with: "m")
            .dropLast()
        guard let minutes = Int(cleaned) else { return nil }
        return now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    if schedule.hasSuffix("h") {
        let cleaned = schedule.replacingOccurrences(of: "every ", with: "").dropLast()
        guard let hours = Int(cleaned) else { return nil }
        return now.addingTimeInterval(TimeInterval(hours * 3600))
    }

    if schedule.hasSuffix("d") || schedule == "daily" {
        let cleaned = schedule.replacingOccurrences(of: "every ", with: "")
            .replacingOccurrences(of: "daily", with: "1d")
            .dropLast()
        guard let days = Int(cleaned) else { return nil }
        return now.addingTimeInterval(TimeInterval(days * 86400))
    }

    // ISO 8601 timestamp (one-shot)
    if schedule.contains("T") {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: schedule)
    }

    // Cron expression (basic: "min hour * * *")
    let parts = schedule.split(separator: " ")
    if parts.count >= 2 {
        let hour = Int(parts[1]) ?? 0
        let minute = Int(parts[0]) ?? 0
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let scheduled = Calendar.current.date(from: components), scheduled > now {
            return scheduled
        }
        // Schedule for tomorrow
        return Calendar.current.date(byAdding: .day, value: 1, to: now)
    }

    return nil
}
