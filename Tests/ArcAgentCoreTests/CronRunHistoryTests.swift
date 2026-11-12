import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Durable run history (Option C: medium-uniform)
//
// One attempt = one record. In file mode a JSON file under
// ~/.arc/cron/history/<jobID>/; in tessera mode the per-run kind-3005
// job event *is* the record (read-time decode, no extra publish).
@Suite("Cron Run History", .serialized)
struct CronRunHistoryTests {

    private func tempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-cron-history-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ jobID: String = "j1", started: TimeInterval = 1_000) -> CronRunRecord {
        var run = CronRunRecord(jobID: jobID, startedAt: Date(timeIntervalSince1970: started), output: "hi")
        run.finishedAt = Date(timeIntervalSince1970: started + 5)
        run.status = "ok"
        return run
    }

    @Test("records append per attempt; listRuns is newest-first")
    func appendAndOrder() async throws {
        let dir = tempDir("order")
        let history = FileCronRunHistory(directory: dir)
        try await history.record(record(started: 1_000), jobID: "j1")
        try await history.record(record(started: 2_000), jobID: "j1")
        try await history.record(record(started: 3_000), jobID: "j1")
        let runs = try await history.listRuns(jobID: "j1", limit: 50)
        #expect(runs.count == 3)
        #expect(runs.first?.startedAt == Date(timeIntervalSince1970: 3_000), "newest first")
        #expect(runs.last?.startedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("the 50-cap is a read-time limit — no files are ever deleted by listing")
    func capIsReadTime() async throws {
        let dir = tempDir("cap")
        let history = FileCronRunHistory(directory: dir)
        for i in 0..<60 {
            try await history.record(record(started: Double(i)), jobID: "j1")
        }
        let limited = try await history.listRuns(jobID: "j1", limit: 50)
        #expect(limited.count == 50)
        #expect(limited.first?.startedAt.timeIntervalSince1970 == 59, "the 50 NEWEST, not the first 50 written")
        // nothing was deleted
        let all = try await history.listRuns(jobID: "j1", limit: 1_000)
        #expect(all.count == 60)
    }

    @Test("prune removes the OLDEST files, keeping the newest N")
    func pruneKeepsNewest() async throws {
        let dir = tempDir("prune")
        let history = FileCronRunHistory(directory: dir)
        for i in 0..<10 {
            try await history.record(record(started: Double(i)), jobID: "j1")
        }
        try await history.prune(jobID: "j1", keep: 3)
        let runs = try await history.listRuns(jobID: "j1", limit: 1_000)
        #expect(runs.count == 3)
        #expect(runs.first?.startedAt.timeIntervalSince1970 == 9)
        #expect(runs.last?.startedAt.timeIntervalSince1970 == 7)
    }

    @Test("a corrupted record file is skipped, not thrown")
    func corruptedSkipped() async throws {
        let dir = tempDir("corrupt")
        let history = FileCronRunHistory(directory: dir)
        try await history.record(record(started: 1_000), jobID: "j1")
        let jobDir = dir.appendingPathComponent("j1", isDirectory: true)
        try Data("not json".utf8).write(to: jobDir.appendingPathComponent("garbage.json"))
        try await history.record(record(started: 2_000), jobID: "j1")
        let runs = try await history.listRuns(jobID: "j1", limit: 50)
        #expect(runs.count == 2)
    }

    @Test("records live outside the job JSON — the job file stays small")
    func historyNotInJobPayload() async throws {
        let jobs = tempDir("jobs")
        let store = FileCronStore(directory: jobs)
        var job = CronJob(id: "j1", name: "x", schedule: "5m", prompt: "p")
        job.lastOutput = String(repeating: "x", count: 4_096)
        try await store.save(job)
        let data = try Data(contentsOf: jobs.appendingPathComponent("j1.json"))
        #expect(data.count < 6_000)
    }

    // MARK: tessera decode path (pure — no server)

    @Test("tessera decode: N per-run events → N newest-first records")
    func tesseraDecodeNewestFirst() throws {
        var old = CronJob(id: "j1", name: "x", schedule: "5m", prompt: "p")
        old.runCount = 1
        old.lastStatus = "ok"
        old.lastStartedAt = Date(timeIntervalSince1970: 1_000)
        old.lastFinishedAt = Date(timeIntervalSince1970: 1_005)
        old.lastOutput = "first"
        var new = old
        new.runCount = 2
        new.lastStatus = "error"
        new.lastStartedAt = Date(timeIntervalSince1970: 2_000)
        new.lastFinishedAt = Date(timeIntervalSince1970: 2_003)
        new.lastOutput = "second"
        new.lastError = "boom"
        let records = [
            tessEvent("arc/cron/j1/1", encodeJob(old, seq: 1)),
            tessEvent("arc/cron/j1/2", encodeJob(new, seq: 2)),
        ]
        let runs = TesseraCronRunHistory.runs(from: records, jobID: "j1", limit: 50)
        #expect(runs.count == 2)
        #expect(runs[0].status == "error", "highest seq first")
        #expect(runs[0].error == "boom")
        #expect(runs[1].output == "first")
        #expect(runs[1].startedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("tessera decode: an event predating the status fields is not a run (no stamp)")
    func tesseraDecodeLegacyPayload() throws {
        var legacy = CronJob(id: "j1", name: "x", schedule: "5m", prompt: "p")
        legacy.runCount = 1
        legacy.lastOutput = "legacy"
        // no lastStatus/lastStartedAt — the pre-Phase-2 shape. Without a
        // start time there is no way to tell a run from a state save, and
        // rendering it as a run produced the Dec-31-1969 phantom.
        let records = [
            tessEvent("arc/cron/j1/1", encodeJob(legacy, seq: 1)),
        ]
        let runs = TesseraCronRunHistory.runs(from: records, jobID: "j1", limit: 50)
        #expect(runs.isEmpty)
    }

    @Test("tessera decode: limit honored, other jobs' events ignored")
    func tesseraDecodeLimitAndFilter() throws {
        var a = CronJob(id: "a", name: "a", schedule: "5m", prompt: "p")
        a.lastStatus = "ok"; a.lastStartedAt = Date(timeIntervalSince1970: 1)
        var b = CronJob(id: "b", name: "b", schedule: "5m", prompt: "p")
        b.lastStatus = "ok"; b.lastStartedAt = Date(timeIntervalSince1970: 2)
        // distinct runs need distinct startedAt — equal stamps are one run
        var a2 = a
        a2.lastStartedAt = Date(timeIntervalSince1970: 3)
        var records = [(seq: 1, job: a), (seq: 2, job: b), (seq: 3, job: a2)].map {
            tessEvent("arc/cron/\($0.job.id)/\($0.seq)", encodeJob($0.job, seq: $0.seq))
        }
        records.remove(at: 1) // drop job b; job a keeps seq 1 and 3
        #expect(TesseraCronRunHistory.runs(from: records, jobID: "a", limit: 50).count == 2)
        #expect(TesseraCronRunHistory.runs(from: records, jobID: "a", limit: 1).count == 1)
    }

    @Test("tessera decode: same-run snapshots (equal startedAt) collapse to one record")
    func tesseraDecodeSameRunCollapse() throws {
        // one run, saved four times (UI update + scheduler + stale saves) —
        // the shape the live store showed for the smoke job
        var job = CronJob(id: "j1", name: "x", schedule: "5m", prompt: "p")
        job.lastStatus = "ok"
        job.lastStartedAt = Date(timeIntervalSince1970: 1_000)
        job.lastOutput = "SMOKE-OK"
        var records = [1, 2, 3, 4].map { seq in
            tessEvent("arc/cron/j1/\(seq)", encodeJob(job, seq: seq))
        }
        // a DIFFERENT run (new startedAt) must not collapse into it
        var next = job
        next.lastStartedAt = Date(timeIntervalSince1970: 2_000)
        next.runCount = job.runCount + 1
        records.append(tessEvent("arc/cron/j1/5", encodeJob(next, seq: 5)))

        let runs = TesseraCronRunHistory.runs(from: records, jobID: "j1", limit: 50)
        #expect(runs.count == 2, "four snapshots of one run + one new run")
        #expect(runs[0].startedAt == Date(timeIntervalSince1970: 2_000), "newest first")
        #expect(runs[1].startedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("tessera decode: a snapshot without lastStartedAt (creation/edit save) is not a run")
    func tesseraDecodeSkipsUnstampedSnapshots() throws {
        var fresh = CronJob(id: "phantom", name: "n", schedule: "1m", prompt: "p")
        fresh.lastStartedAt = nil          // creation snapshot — never run
        fresh.lastOutput = nil
        var run = fresh
        run.lastStartedAt = Date(timeIntervalSince1970: 1_000)
        run.lastStatus = "ok"
        run.lastOutput = "Confirmation"
        let records = [
            tessEvent("arc/cron/phantom/1", encodeJob(fresh, seq: 1)),
            tessEvent("arc/cron/phantom/2", encodeJob(run, seq: 2)),
        ]
        let out = TesseraCronRunHistory.runs(from: records, jobID: "phantom", limit: 10)
        #expect(out.count == 1, "the creation snapshot must not render as a Dec 31 1969 phantom run")
        #expect(out.first?.startedAt == Date(timeIntervalSince1970: 1_000))
    }

    private func tessEvent(_ dTag: String, _ content: String) -> TesseraRecord {
        TesseraRecord(id: nil, dTag: dTag, content: content, author: "test")
    }

    private func encodeJob(_ job: CronJob, seq: Int) -> String {
        let record = TesseraCronRecord(seq: seq, job: job)
        return String(decoding: try! JSONEncoder().encode(record), as: UTF8.self)
    }
}

// MARK: - Scheduler single-save rule

@Suite("Cron Run History Scheduler", .serialized)
struct CronRunHistorySchedulerTests {

    /// A store that counts saves and keeps history of what it was asked to save.
    private actor CountingStore: CronStore {
        var saves = 0
        var job: CronJob
        init(job: CronJob) { self.job = job }
        func save(_ job: CronJob) async throws { saves += 1; self.job = job }
        func get(id: String) async throws -> CronJob? { job }
        func delete(id: String) async throws {}
        func listActive() async throws -> [CronJob] { [job] }
        func listAll() async throws -> [CronJob] { [job] }
    }

    @Test("a run stamps last* fields and performs exactly ONE store.save")
    func singleSavePerRun() async throws {
        var job = CronJob(id: "j1", name: "x", schedule: "5m", prompt: "p")
        job.nextRunAt = Date().addingTimeInterval(-60)
        let store = CountingStore(job: job)
        let history = FileCronRunHistory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-cron-single-\(UUID().uuidString)", isDirectory: true))
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, history: history, jobRunner: { _ in CronRunResult(output: "ran!") })
        try await scheduler.runDueJobs()
        let saved = await store.job
        #expect(await store.saves == 1, "exactly one save per run — never record() + save")
        #expect(saved.lastStatus == "ok")
        #expect(saved.lastStartedAt != nil)
        #expect(saved.lastFinishedAt != nil)
        #expect(saved.lastOutput == "ran!")
        #expect(saved.runCount == 1)
        let runs = try await history.listRuns(jobID: "j1", limit: 10)
        #expect(runs.count == 1, "file-mode history recorded alongside the single save")
    }

    @Test("a failed run records status 'error' and still advances the schedule")
    func failureRecordsError() async throws {
        var job = CronJob(id: "j2", name: "x", schedule: "5m", prompt: "p")
        job.nextRunAt = Date().addingTimeInterval(-60)
        let store = CountingStore(job: job)
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: { _ in throw TestFailure() })
        try await scheduler.runDueJobs()
        let saved = await store.job
        #expect(saved.lastStatus == "error")
        #expect(saved.lastError != nil)
        #expect(saved.nextRunAt != nil, "schedule advances even on failure")
    }
}

struct TestFailure: Error {}
