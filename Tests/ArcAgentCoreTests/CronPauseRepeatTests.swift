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

    @Test("runBudget=3 runs exactly 3 times then deactivates with a final record")
    func runBudget() async throws {
        let store = tempStore()
        let dir = (store as! FileCronStore).homeDirectory
        let history = FileCronRunHistory(directory: dir.appendingPathComponent("history", isDirectory: true))
        var job = CronJob(name: "r", schedule: "* * * * *", prompt: "x")
        job.runBudget = 3
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

    @Test("a FAILED run consumes no budget — the job stays retryable")
    func failedRunConsumesNoBudget() async throws {
        let store = tempStore()
        let dir = (store as! FileCronStore).homeDirectory
        let history = FileCronRunHistory(directory: dir.appendingPathComponent("history", isDirectory: true))
        var job = CronJob(name: "f", schedule: "", prompt: "x")
        job.runBudget = 1
        job.runsRemaining = 1
        job.nextRunAt = Date(timeIntervalSince1970: 0)
        try await store.save(job)
        let flag = FlagBox()
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, timeZone: TimeZone(identifier: "UTC")!, history: history, jobRunner: { _ in
            if flag.value {
                flag.value = false
                throw CronRunnerError("boom")
            }
            return CronRunResult(output: "ok")
        })
        // Pass 1 fires the job and fails; the manual re-arm (what Run now
        // does) makes pass 2 retry it.
        try await scheduler.runDueJobs(now: Date(timeIntervalSince1970: 0))
        var afterFail = try await store.get(id: job.id)!
        #expect(afterFail.runsRemaining == 1, "failure consumes no budget")
        #expect(afterFail.lastStatus == "error")
        #expect(afterFail.isActive, "a failed one-shot is not retired")
        afterFail.nextRunAt = Date(timeIntervalSince1970: 120)
        try await store.save(afterFail)
        try await scheduler.runDueJobs(now: Date(timeIntervalSince1970: 120))
        let afterRetry = try await store.get(id: job.id)!
        #expect(afterRetry.runsRemaining == 0, "success consumes the budget")
        #expect(afterRetry.lastStatus == "ok")
        #expect(!afterRetry.isActive, "the succeeded one-shot retires")
    }

    @Test("a one-shot cannot be paused; a spent one-shot cannot run again")
    func oneShotOpRefusals() async throws {
        let store = tempStore()
        var one = CronJob(name: "once", schedule: "2026-01-01T09:00:00", prompt: "x")
        one.runBudget = 1
        one.runsRemaining = 1
        try await store.save(one)
        await #expect(throws: CronOpsError.self) {
            try await CronOps.pause(store: store, id: one.id, reason: "nope")
        }
        // Spent → run refused.
        one.runsRemaining = 0
        one.lastStatus = "ok"
        try await store.save(one)
        await #expect(throws: CronOpsError.self) {
            try await CronOps.runNow(store: store, id: one.id)
        }
        // Failed → run allowed (retry).
        one.lastStatus = "error"
        try await store.save(one)
        let armed = try await CronOps.runNow(store: store, id: one.id)
        #expect(armed.nextRunAt != nil, "a failed one-shot re-arms for retry")
    }

    @Test("a one-shot cannot have a recurring schedule (create and edit)")
    func oneShotNotRecurring() async throws {
        let store = tempStore()
        await #expect(throws: CronOpsError.self) {
            try await CronOps.create(store: store, name: "bad", schedule: "0 9 * * *",
                                     prompt: "x", runBudget: 1)
        }
        let ok = try await CronOps.create(store: store, name: "good", schedule: "2026-06-01T09:00:00",
                                          prompt: "x", runBudget: 1)
        #expect(ok.isOneShot)
        await #expect(throws: CronOpsError.self) {
            try await CronOps.edit(store: store, id: ok.id, schedule: "every 5m")
        }
        let manual = try await CronOps.create(store: store, name: "manual", schedule: "",
                                              prompt: "x", runBudget: 1)
        #expect(manual.nextRunAt == nil, "a schedule-less one-shot arms only via Run now")
    }

    @Test("a FUTURE one-shot that fires (manual arm) is not re-armed to its own instant")
    func oneShotNotRearmed() async throws {
        let store = tempStore()
        let dir = (store as! FileCronStore).homeDirectory
        let history = FileCronRunHistory(directory: dir.appendingPathComponent("history", isDirectory: true))
        // The "Current weather check" shape: a one-shot ISO in the far
        // future, armed by Run now. The old re-arm pointed nextRunAt back
        // at 2099 — the job sat Active forever.
        var job = CronJob(name: "w", schedule: "2099-01-01T00:00:00Z", prompt: "x")
        job.nextRunAt = Date(timeIntervalSince1970: 0)
        try await store.save(job)
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, timeZone: TimeZone(identifier: "UTC")!, history: history, jobRunner: { _ in
            CronRunResult(output: "ran")
        })
        try await scheduler.runDueJobs(now: Date(timeIntervalSince1970: 0))
        let final = try await store.get(id: job.id)!
        #expect(final.runCount == 1)
        #expect(final.nextRunAt == nil, "a fired one-shot is never re-armed")
        #expect(final.lastStatus == "ok")
    }

    @Test("self-heal: a stale future arm on an already-fired one-shot is cleared")
    func staleFutureArmHealed() async throws {
        let store = tempStore()
        let dir = (store as! FileCronStore).homeDirectory
        let history = FileCronRunHistory(directory: dir.appendingPathComponent("history", isDirectory: true))
        // Data written by the pre-fix re-arm: fired once, yet armed for 2099.
        var job = CronJob(name: "stale", schedule: "2099-06-01T00:00:00Z", prompt: "x")
        job.lastRunAt = Date(timeIntervalSince1970: 0)
        job.runCount = 1
        job.nextRunAt = Date(timeIntervalSince1970: 4_000_000_000)
        try await store.save(job)
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, timeZone: TimeZone(identifier: "UTC")!, history: history, jobRunner: { _ in
            Issue.record("the stale arm must be cleared without firing")
            return CronRunResult(output: "")
        })
        try await scheduler.runDueJobs(now: Date(timeIntervalSince1970: 60))
        let final = try await store.get(id: job.id)!
        #expect(final.nextRunAt == nil, "the stale future arm is gone")
        #expect(final.runCount == 1, "no phantom run")
    }

    @Test("runsRemaining persists in the job payload (survives save/load round-trip)")
    func runsRemainingPersists() throws {
        var job = CronJob(name: "x", schedule: "1h", prompt: "p")
        job.runBudget = 5
        job.runsRemaining = 5
        let data = try JSONEncoder().encode(job)
        let back = try JSONDecoder().decode(CronJob.self, from: data)
        #expect(back.runBudget == 5)
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

/// A throwaway error the fake runner throws to simulate a failed run.
private struct CronRunnerError: Error { let message: String; init(_ m: String) { message = m } }

/// Sendable mutable flag for closures the scheduler executes concurrently.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = true
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); defer { lock.unlock() }; v = newValue }
    }
}
