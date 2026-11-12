import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - One-shot afterlife (§ completed vs dead schedules)
//
// A schedule that yields no next run is two very different situations:
// a SPENT one-shot (fired once, done — completion) and a DEAD job
// (never fired, garbage schedule). The old scheduler warned and saved
// on EVERY poll pass for both. These tests pin the split: completion
// announces once at info and never saves; death warns once and never
// saves (the state does not change pass to pass).

@Suite("Cron One-shot Afterlife")
struct CronOneShotAfterlifeTests {

    /// Delegating store that counts `save` calls — the churn probe.
    private actor CountingStore: CronStore {
        let backing: FileCronStore
        private(set) var saves = 0
        init(backing: FileCronStore) { self.backing = backing }
        func save(_ job: CronJob) async throws {
            saves += 1
            try await backing.save(job)
        }
        func get(id: String) async throws -> CronJob? { try await backing.get(id: id) }
        func delete(id: String) async throws { try await backing.delete(id: id) }
        func listActive() async throws -> [CronJob] { try await backing.listActive() }
        func listAll() async throws -> [CronJob] { try await backing.listAll() }
    }

    private func tempStore() -> FileCronStore {
        FileCronStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-oneshot-\(UUID().uuidString)", isDirectory: true))
    }

    private static let pastISO = "2020-01-01T08:00:00-06:00"

    @Test("a spent one-shot never fires again and never saves per pass")
    func spentOneShotIsQuiet() async throws {
        let store = CountingStore(backing: tempStore())
        var job = CronJob(name: "spent", schedule: Self.pastISO, prompt: "x")
        job.lastStartedAt = Date(timeIntervalSince1970: 0)  // HAS fired
        job.nextRunAt = nil
        try await store.save(job)
        let ran = RunCounter()
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: { _ in
            await ran.hit()
            return CronRunResult(output: "ran")
        })
        for _ in 0..<3 { try await scheduler.runDueJobs() }
        #expect(await ran.hits() == 0, "a spent one-shot never fires again")
        let saves = await store.saves
        #expect(saves <= 1, "no per-pass save churn for a completed job (got \(saves) saves)")
        let stored = try await store.get(id: job.id)!
        #expect(stored.nextRunAt == nil)
        #expect(stored.runCount == 0, "bookkeeping runs are fake records — none for a completed job")
    }

    @Test("a dead never-fired job stays inactive-but-loud without save churn")
    func deadJobWarnsOnceNotEveryPass() async throws {
        let store = CountingStore(backing: tempStore())
        var job = CronJob(name: "dead", schedule: Self.pastISO, prompt: "x")
        job.lastStartedAt = nil  // never fired — genuinely dead
        job.nextRunAt = nil
        try await store.save(job)
        let ran = RunCounter()
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: { _ in
            await ran.hit()
            return CronRunResult(output: "ran")
        })
        for _ in 0..<3 { try await scheduler.runDueJobs() }
        #expect(await ran.hits() == 0)
        let saves = await store.saves
        #expect(saves <= 1, "warning once does not mean saving every pass (got \(saves) saves)")
    }

    @Test("re-arming a completed one-shot (edit to a future schedule) makes it fire again")
    func rearmAfterCompletion() async throws {
        let store = CountingStore(backing: tempStore())
        var job = CronJob(name: "rearm", schedule: Self.pastISO, prompt: "x")
        job.lastStartedAt = Date(timeIntervalSince1970: 0)
        job.nextRunAt = nil
        try await store.save(job)
        let ran = RunCounter()
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: { _ in
            await ran.hit()
            return CronRunResult(output: "ran")
        })
        try await scheduler.runDueJobs()
        #expect(await ran.hits() == 0)
        // The user edits the schedule to a future one-shot: the job runs again.
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let future = stamp.string(from: Date().addingTimeInterval(60))
        _ = try await CronOps.edit(store: store, id: job.id, schedule: future)
        // A pass before the moment: no fire, next run armed.
        try await scheduler.runDueJobs()
        #expect(await ran.hits() == 0)
        // A pass after the moment: fires exactly once, then completes again.
        try await scheduler.runDueJobs(now: Date().addingTimeInterval(120))
        #expect(await ran.hits() == 1, "an edited (re-armed) one-shot fires again")
    }
}
