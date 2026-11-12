import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Vascular hardening: one run per job, edits survive an in-flight run

@Suite("Cron Run Gate & Lost-Update")
struct CronRunGateTests {

    private func tempStore() -> FileCronStore {
        FileCronStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-rungate-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("gate: a job already running (held slot) is skipped by the scheduler pass")
    func gateSkipsInFlightJob() async throws {
        let store = tempStore()
        var job = CronJob(name: "g", schedule: "* * * * *", prompt: "x")
        job.nextRunAt = Date().addingTimeInterval(-10)  // due
        try await store.save(job)

        let gate = CronRunGate.shared
        let acquired = await gate.tryAcquire(job.id)
        #expect(acquired, "test holds the slot to simulate a manual Run-now mid-turn")

        let ran = RunCounter()
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: { _ in
            await ran.hit()
            return CronRunResult(output: "ran")
        })
        try await scheduler.runDueJobs()
        #expect(await ran.hits() == 0, "scheduler must not double-fire a gated job")
        let untouched = try await store.get(id: job.id)!
        #expect(untouched.runCount == 0, "no phantom run bookkeeping")

        await gate.release(job.id)
        try await scheduler.runDueJobs()
        #expect(await ran.hits() == 1, "after release the job fires normally")
    }

    @Test("gate: withJob returns nil without running body when held")
    func withJobNilWhenHeld() async throws {
        let gate = CronRunGate.shared
        let id = UUID().uuidString
        await gate.tryAcquire(id)
        let result = try await gate.withJob(id) { 42 }
        #expect(result == nil)
        await gate.release(id)
        let second = try await gate.withJob(id) { 42 }
        #expect(second == 42)
        await gate.release(id)
    }

    @Test("lost update: an edit landing mid-run survives the post-run save")
    func editSurvivesInFlightRun() async throws {
        let store = tempStore()
        var job = CronJob(name: "before-edit", schedule: "* * * * *", prompt: "x")
        job.nextRunAt = Date().addingTimeInterval(-10)  // due
        try await store.save(job)

        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: { runJob in
            // the turn takes wall-clock time; the user edits mid-run
            var edited = runJob
            edited.name = "after-edit"
            edited.prompt = "edited prompt"
            try await store.save(edited)
            return CronRunResult(output: "ran")
        })
        try await scheduler.runDueJobs()

        let after = try await store.get(id: job.id)!
        #expect(after.name == "after-edit", "the mid-run edit must not be reverted")
        #expect(after.prompt == "edited prompt")
        #expect(after.runCount == 1, "run bookkeeping still lands")
        #expect(after.lastStatus == "ok")
        #expect(after.lastOutput == "ran")
        #expect(after.nextRunAt != nil, "re-armed against the (new) schedule")
    }

    @Test("lost update: a job deleted mid-run is NOT resurrected by the post-run save")
    func deletedMidRunStaysDeleted() async throws {
        let store = tempStore()
        var job = CronJob(name: "d", schedule: "* * * * *", prompt: "x")
        job.nextRunAt = Date().addingTimeInterval(-10)
        try await store.save(job)
        let jobID = job.id

        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: { _ in
            // the user deletes the job while its turn is running
            try await store.delete(id: jobID)
            return CronRunResult(output: "ran")
        })
        try await scheduler.runDueJobs()
        #expect(try await store.get(id: jobID) == nil, "no resurrection from the stale pass copy")
    }

    @Test("lost update: a concurrent writer's higher runCount is not clobbered")
    func concurrentRunCountWins() async throws {
        let store = tempStore()
        var job = CronJob(name: "c", schedule: "* * * * *", prompt: "x")
        job.runCount = 10
        job.nextRunAt = Date().addingTimeInterval(-10)
        try await store.save(job)
        let jobID = job.id

        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: { _ in
            // another writer (UI Run-now) counted a run while ours was going
            var bump = try await store.get(id: jobID)!
            bump.runCount += 1
            try await store.save(bump)
            return CronRunResult(output: "ran")
        })
        try await scheduler.runDueJobs()
        let after = try await store.get(id: job.id)!
        #expect(after.runCount == 12, "both attempts are counted, neither lost")
    }
}
