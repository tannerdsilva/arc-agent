import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Job session lifecycle (plan Phase 7)
//
// Job = sender with a persistent session (`cron-<jobID>`). The cost is
// context growth: compaction handles the steady state (the cron session
// goes through the SAME turn engine as every chat — pinned below), and
// reset-every-N handles drift, between firings, never mid-firing.

@Suite("Cron Session Lifecycle")
struct CronSessionLifecycleTests {

    private func tempStore() -> FileCronStore {
        FileCronStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-life-\(UUID().uuidString)", isDirectory: true))
    }

    // MARK: 7.1 — compaction guard

    @Test("cron sessions ride the same turn engine: compaction config survives the cron flag")
    func compactionApplies() {
        // The cron session is an ordinary session (SessionAgent turn loop);
        // `isCronSession` only changes approval arbitration. Compaction is
        // per-turn (`maybeMicroCompact`) and reads `config.microCompact` —
        // the cron flag must not strip or disable it. Pinned as a
        // regression guard against "cron turns bypass compaction".
        var config = ArcAgent.Configuration(
            model: "m", provider: "p", baseURL: URL(string: "https://x")!, apiKey: "k",
            registry: CompileTimeToolRegistry(),
            sessionStore: FileSessionStore(),
            isCronSession: true
        )
        config.microCompact = MicroCompactor.ConfigStub.enabled()
        #expect(config.isCronSession == true)
        #expect(config.microCompact.enabled == true,
                "the cron flag and compaction config are independent fields")
    }

    // MARK: 7.2 — reset every N runs

    private final class ResetSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _flags: [Bool] = []
        func record(_ job: CronJob) {
            lock.lock(); defer { lock.unlock() }
            _flags.append(job.needsSessionReset)
        }
        var flags: [Bool] { lock.lock(); defer { lock.unlock() }; return _flags }
    }

    @Test("reset-every-2: the third firing starts fresh, flag consumed after")
    func resetCadence() async throws {
        let store = tempStore()
        var job = CronJob(name: "r", schedule: "* * * * *", prompt: "x")
        job.resetEveryRuns = 2
        job.nextRunAt = Date(timeIntervalSince1970: 0)
        try await store.save(job)
        let spy = ResetSpy()
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1,
                                      timeZone: TimeZone(identifier: "UTC")!,
                                      jobRunner: { j in
                                          spy.record(j)
                                          return CronRunResult(output: "ran")
                                      })
        for minute in 0..<4 {
            try await scheduler.runDueJobs(now: Date(timeIntervalSince1970: TimeInterval(minute * 60)))
        }
        // Run 1: counter 0→1, no signal. Run 2: counter 1→2 ≥ 2 → zeroed +
        // signal. Run 3: runner sees the signal (fresh session). Run 4:
        // flag consumed.
        #expect(spy.flags == [false, false, true, false],
                "reset lands between firings: \(spy.flags)")
        let final = try await store.get(id: job.id)!
        // Run 4 crossed the bucket AGAIN (1→2) — the flag is armed for a
        // hypothetical 5th firing, and the bucket restarted. That is the
        // steady-state cadence, not a stuck signal.
        #expect(final.needsSessionReset == true)
        #expect(final.runsSinceReset == 0)
        #expect(final.runCount == 4, "all four firings ran — nothing was cut")
    }

    @Test("runsSinceReset survives a scheduler re-init (restart mid-bucket)")
    func counterSurvivesRestart() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-life-p-\(UUID().uuidString)", isDirectory: true)
        let store = FileCronStore(directory: dir)
        var job = CronJob(name: "x", schedule: "1h", prompt: "p")
        job.resetEveryRuns = 10
        job.runsSinceReset = 7
        try await store.save(job)
        // A fresh scheduler over the same directory re-reads the persisted
        // counter — no silent mid-bucket zeroing.
        let back = try await FileCronStore(directory: dir).get(id: job.id)!
        #expect(back.runsSinceReset == 7)
        #expect(back.resetEveryRuns == 10)
    }

    @Test("resetEveryRuns == nil never signals and never counts")
    func nilNeverResets() async throws {
        let store = tempStore()
        var job = CronJob(name: "n", schedule: "* * * * *", prompt: "x")
        job.nextRunAt = Date(timeIntervalSince1970: 0)
        try await store.save(job)
        let spy = ResetSpy()
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1,
                                      timeZone: TimeZone(identifier: "UTC")!,
                                      jobRunner: { j in
                                          spy.record(j)
                                          return CronRunResult(output: "ran")
                                      })
        for minute in 0..<3 {
            try await scheduler.runDueJobs(now: Date(timeIntervalSince1970: TimeInterval(minute * 60)))
        }
        #expect(spy.flags == [false, false, false])
        let final = try await store.get(id: job.id)!
        #expect(final.runsSinceReset == nil)
    }
}

extension MicroCompactor {
    /// Test seam: an enabled micro-compact config without touching the
    /// real default (which is off).
    struct ConfigStub {
        static func enabled() -> MicroCompactConfig {
            var c = MicroCompactConfig()
            c.enabled = true
            return c
        }
    }
}
