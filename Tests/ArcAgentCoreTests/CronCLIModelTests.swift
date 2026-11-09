import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Cron management operations (shared by `arc cron …` and, later,
// the agent tool). Tests exercise CronOps — the pure mutation helpers —
// not AsyncParsableCommand I/O.

@Suite("Cron CLI Model")
struct CronCLIModelTests {

    private func tempStore() -> (FileCronStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-cronops-\(UUID().uuidString)", isDirectory: true)
        return (FileCronStore(directory: dir), dir)
    }

    @Test("create writes a job with a valid schedule and computed next run")
    func createOK() async throws {
        let (store, _) = tempStore()
        let job = try await CronOps.create(store: store, name: "ping",
                                           schedule: "*/5 * * * *", prompt: "say hi")
        #expect(job.isActive)
        #expect(job.prompt == "say hi")
        let fetched = try await store.get(id: job.id)
        #expect(fetched?.name == "ping")
    }

    @Test("create rejects an invalid schedule with a legible error")
    func createRejectsGarbage() async throws {
        let (store, _) = tempStore()
        await #expect(throws: CronOpsError.self) {
            try await CronOps.create(store: store, name: "x", schedule: "not a schedule", prompt: "p")
        }
        #expect(try await store.listAll().isEmpty, "nothing persisted for a rejected create")
    }

    @Test("edit revalidates the schedule and recomputes nextRunAt")
    func editRecomputes() async throws {
        let (store, _) = tempStore()
        let job = try await CronOps.create(store: store, name: "e", schedule: "1d", prompt: "p")
        let edited = try await CronOps.edit(store: store, id: job.id, schedule: "0 9 * * mon")
        #expect(edited.schedule == "0 9 * * mon")
        #expect(edited.nextRunAt != nil, "edit recomputes the next fire date")
        #expect(edited.nextRunAt != job.nextRunAt, "the new schedule changed the fire time")
    }

    @Test("edit rejects an invalid schedule and leaves the job untouched")
    func editRejectsGarbage() async throws {
        let (store, _) = tempStore()
        let job = try await CronOps.create(store: store, name: "e", schedule: "1h", prompt: "p")
        await #expect(throws: CronOpsError.self) {
            try await CronOps.edit(store: store, id: job.id, schedule: "99 9 * * *")
        }
        let untouched = try await store.get(id: job.id)
        #expect(untouched?.schedule == "1h")
    }

    @Test("pause sets isActive=false and stamps pausedAt")
    func pauseStamps() async throws {
        let (store, _) = tempStore()
        let job = try await CronOps.create(store: store, name: "p", schedule: "1h", prompt: "x")
        let paused = try await CronOps.pause(store: store, id: job.id)
        #expect(!paused.isActive)
        #expect(paused.pausedAt != nil)
    }

    @Test("resume recomputes nextRunAt from now — no catch-up burst")
    func resumeNoCatchUp() async throws {
        let (store, _) = tempStore()
        var job = try await CronOps.create(store: store, name: "r", schedule: "30m", prompt: "x")
        job = try await CronOps.pause(store: store, id: job.id)
        // Pretend the pause lasted a week: the stale nextRunAt is long past.
        let stale = Date().addingTimeInterval(-7 * 86_400)
        var revived = job
        revived.nextRunAt = stale
        try await store.save(revived)
        let resumed = try await CronOps.resume(store: store, id: job.id)
        #expect(resumed.isActive)
        #expect(resumed.pausedAt == nil)
        #expect(resumed.nextRunAt != nil)
        #expect(resumed.nextRunAt! > Date(), "next run is in the future — the stale slot is discarded")
        #expect(resumed.nextRunAt! <= Date().addingTimeInterval(30 * 60 + 5))
    }

    @Test("remove deletes the job JSON and its history directory")
    func removeCleansHistory() async throws {
        let (store, dir) = tempStore()
        let job = try await CronOps.create(store: store, name: "d", schedule: "1h", prompt: "x")
        let historyDir = dir.appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent(job.id, isDirectory: true)
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: historyDir.appendingPathComponent("0000000000000001-abc.json"))
        try await CronOps.remove(store: store, id: job.id)
        #expect(try await store.get(id: job.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: historyDir.path),
                "the job's run history goes with it")
    }

    @Test("runNow sets nextRunAt to now — fires on the next scheduler pass")
    func runNowSchedules() async throws {
        let (store, _) = tempStore()
        let job = try await CronOps.create(store: store, name: "n", schedule: "1h", prompt: "x")
        let before = Date().addingTimeInterval(-5)
        let armed = try await CronOps.runNow(store: store, id: job.id)
        #expect(armed.nextRunAt! > before, "armed for the next pass, not executed inline")
        #expect(armed.nextRunAt! <= Date() + 1, "…and that pass is now")
    }

    @Test("unknown ids surface a CronOpsError, not a silent no-op")
    func unknownID() async throws {
        let (store, _) = tempStore()
        await #expect(throws: CronOpsError.self) { try await CronOps.pause(store: store, id: "nope") }
        await #expect(throws: CronOpsError.self) { try await CronOps.resume(store: store, id: "nope") }
        await #expect(throws: CronOpsError.self) { try await CronOps.runNow(store: store, id: "nope") }
    }

    @Test("due-now detection matches the scheduler's window")
    func dueNow() async throws {
        var due = CronJob(name: "d", schedule: "1h", prompt: "x")
        due.nextRunAt = Date().addingTimeInterval(-60)
        #expect(CronOps.isDue(due, now: Date()))
        var future = CronJob(name: "f", schedule: "1h", prompt: "x")
        future.nextRunAt = Date().addingTimeInterval(3600)
        #expect(!CronOps.isDue(future, now: Date()))
        var stopped = CronJob(name: "s", schedule: "1h", prompt: "x")
        stopped.nextRunAt = Date().addingTimeInterval(-60)
        stopped.isActive = false
        #expect(!CronOps.isDue(stopped, now: Date()), "inactive jobs are never due")
    }
}
