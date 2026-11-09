import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Pause that survives, repeat budgets (plan Phase 6.1)

@Suite("Cron Pause Repeat")
struct CronPauseRepeatTests {

    private func tempStore() -> FileCronStore {
        FileCronStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-pause-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("paused job never fires across N passes; resume recomputes without firing")
    func pauseAcrossPasses() async throws {
        let store = tempStore()
        var job = CronJob(name: "p", schedule: "1h", prompt: "x")
        job.nextRunAt = Date().addingTimeInterval(-10)  // due
        try await store.save(job)
        let ran = RunCounter()
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: { _ in
            await ran.hit()
            return CronRunResult(output: "ran")
        })
        _ = try await CronOps.pause(store: store, id: job.id, reason: "maintenance")
        for _ in 0..<3 { try await scheduler.runDueJobs() }
        #expect(await ran.hits() == 0, "paused jobs never fire")
        let paused = try await store.get(id: job.id)!
        #expect(paused.pausedAt != nil)
        #expect(paused.pausedReason == "maintenance")
        try await CronOps.resume(store: store, id: job.id)
        let resumed = try await store.get(id: job.id)!
        #expect(resumed.pausedAt == nil)
        #expect(resumed.nextRunAt != nil, "resume re-arms without firing")
        #expect(await ran.hits() == 0)
    }

    @Test("repeat=3 runs exactly 3 times then deactivates with a final record")
    func repeatBudget() async throws {
        let store = tempStore()
        let dir = (store as! FileCronStore).homeDirectory
        let history = FileCronRunHistory(directory: dir.appendingPathComponent("history", isDirectory: true))
        var job = CronJob(name: "r", schedule: "* * * * *", prompt: "x")
        job.repeatBudget = 3
        job.nextRunAt = Date(timeIntervalSince1970: 0)
        try await store.save(job)
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, timeZone: TimeZone(identifier: "UTC")!, history: history, jobRunner: { _ in
            CronRunResult(output: "ran")
        })
        // One pass per minute: each pass sees the previous nextRunAt due.
        for minute in 0..<5 {
            try await scheduler.runDueJobs(now: Date(timeIntervalSince1970: TimeInterval(minute * 60)))
        }
        let final = try await store.get(id: job.id)!
        #expect(final.runCount == 3, "exactly the budget ran: \(final.runCount)")
        #expect(final.isActive == false, "budget exhausted deactivates the job")
        let runs = try await history.listRuns(jobID: job.id, limit: 10)
        #expect(runs.count == 3)
        // The last record carries the completion note in its output trail —
        // the record output is the run output; deactivation is visible on
        // the job itself. (No fake 4th record — bookkeeping isn't a run.)
    }

    @Test("runsRemaining persists in the job payload (survives save/load round-trip)")
    func runsRemainingPersists() throws {
        var job = CronJob(name: "x", schedule: "1h", prompt: "p")
        job.repeatBudget = 5
        job.runsRemaining = 5
        let data = try JSONEncoder().encode(job)
        let back = try JSONDecoder().decode(CronJob.self, from: data)
        #expect(back.repeatBudget == 5)
        #expect(back.runsRemaining == 5)
    }
}


/// Sendable run counter for closures the scheduler executes concurrently.
final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func hit() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func hits() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
