import Testing
@testable import ArcWebUI
import ArcAgentCore

/// The scheduled-tasks mutations must verify their store writes. An
/// optimistic UI on a failed write is exactly how a deleted job
/// "reappeared" after reload: the panel dropped the row, the store kept
/// the record, and the next re-pull resurrected it.
@Suite struct ScheduledTaskVerifiedWriteTests {

    /// In-memory store that can be told to fail writes, simulating the
    /// tessera relay wedging (echo-wait throws, nothing persisted).
    private actor TestStore: CronStore {
        var jobs: [String: CronJob] = [:]
        var failSaves = false
        var failDeletes = false
        private(set) var saveCount = 0
        private(set) var deleteCount = 0

        func setFailing(saves: Bool = false, deletes: Bool = false) {
            failSaves = saves
            failDeletes = deletes
        }

        func save(_ job: CronJob) async throws {
            saveCount += 1
            if failSaves { throw CronStoreError("echo not confirmed") }
            jobs[job.id] = job
        }

        func get(id: String) async throws -> CronJob? { jobs[id] }

        func delete(id: String) async throws {
            deleteCount += 1
            if failDeletes { throw CronStoreError("echo not confirmed") }
            jobs.removeValue(forKey: id)
        }

        func listActive() async throws -> [CronJob] { jobs.values.filter { $0.isActive } }
        func listAll() async throws -> [CronJob] { Array(jobs.values) }
    }

    private func makeApp(store: TestStore, jobs: [CronJob] = [],
                         selected: String? = nil) async -> AppState {
        var f = AppState.RenderFixture()
        f.cronStore = store
        f.settings.scheduledJobs = jobs
        f.tasksSelectedID = selected
        return AppState(renderFixture: f)
    }

    private func sampleJob(name: String = "fixture job") -> CronJob {
        CronJob(name: name, schedule: "*/5 * * * *", prompt: "Reply with exactly: FIXTURE")
    }

    @Test("failed delete keeps the job and the selection, and raises an error toast")
    func deleteFailureKeepsJob() async throws {
        let store = TestStore()
        let job = sampleJob()
        let app = await makeApp(store: store, jobs: [job], selected: job.id)
        try await store.save(job)

        await store.setFailing(deletes: true)
        await app.deleteJob(job.id)

        // The record survived (the write failed), and the page must agree
        // with the store instead of optimistically dropping the row.
        let stillThere = try await store.get(id: job.id)
        #expect(stillThere != nil)
        let cached = await app.settings.scheduledJobs
        #expect(cached.contains { $0.id == job.id })
        let selected = await app.tasksSelectedID
        #expect(selected == job.id)
        let html = await app.toastsHTML().markup.html
        #expect(html.contains("did not confirm"))
    }

    @Test("verified delete removes the record and the cache row")
    func deleteSuccessRemovesJob() async throws {
        let store = TestStore()
        let job = sampleJob()
        let app = await makeApp(store: store, jobs: [job])
        try await store.save(job)

        await app.deleteJob(job.id)

        let gone = try await store.get(id: job.id)
        #expect(gone == nil)
        let cached = await app.settings.scheduledJobs
        #expect(cached.isEmpty)
    }

    @Test("failed create returns nil and raises an error toast")
    func addJobFailureReturnsNil() async throws {
        let store = TestStore()
        let app = await makeApp(store: store)
        await store.setFailing(saves: true)

        let id = await app.addJob(name: "e2e", schedule: "*/5 * * * *", prompt: "p")

        #expect(id == nil)
        let html = await app.toastsHTML().markup.html
        #expect(html.contains("did not confirm"))
    }

    @Test("verified create persists and returns the id")
    func addJobSuccessPersists() async throws {
        let store = TestStore()
        let app = await makeApp(store: store)

        let id = await app.addJob(name: "e2e", schedule: "*/5 * * * *", prompt: "p")

        #expect(id != nil)
        let saved = try await store.get(id: id ?? "")
        #expect(saved != nil)
    }

    @Test("failed edit surfaces an error and leaves the record untouched")
    func editFailureLeavesRecord() async throws {
        let store = TestStore()
        let job = sampleJob()
        let app = await makeApp(store: store, jobs: [job])
        try await store.save(job)

        await store.setFailing(saves: true)
        await app.editJob(job.id, name: "renamed", schedule: "*/7 * * * *", prompt: "new",
                          deliver: nil, profile: nil)

        let after = try await store.get(id: job.id)
        #expect(after?.name == job.name)
        #expect(after?.schedule == job.schedule)
        let html = await app.toastsHTML().markup.html
        #expect(html.contains("did not confirm"))
    }
}

/// Sentinel error mirroring the relay's not-persisted failure.
private struct CronStoreError: Error, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
}
