import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Tessera cron + goal stores (pure helpers, mirror TesseraStorageTests)

@Suite("Tessera cron/goal stores")
struct TesseraCronGoalTests {

    // ── Cron ────────────────────────────────────────────────────────────

    @Test("cron dTag embeds id + sequence")
    func cronDTag() {
        #expect(TesseraCronStore.dTag(for: "j1", seq: 7) == "arc/cron/j1/7")
    }

    @Test("latest cron record per job wins; malformed records are skipped")
    func cronLatestByJob() {
        let old = TesseraCronRecord(seq: 1, job: CronJob(id: "j1", name: "old", schedule: "30m", prompt: "a"))
        let new = TesseraCronRecord(seq: 5, job: CronJob(id: "j1", name: "new", schedule: "1d", prompt: "b"))
        let other = TesseraCronRecord(seq: 2, job: CronJob(id: "j2", name: "other", schedule: "1h", prompt: "c"))

        func record(_ r: TesseraCronRecord) -> TesseraRecord {
            TesseraRecord(
                id: nil,
                dTag: TesseraCronStore.dTag(for: r.job.id, seq: r.seq),
                content: String(decoding: try! JSONEncoder().encode(r), as: UTF8.self))
        }

        let latest = TesseraCronStore.latestByJob(from: [record(old), record(other), record(new),
                                                         TesseraRecord(id: nil, dTag: "arc/cron/j3/1", content: "not json")])
        #expect(latest["j1"]?.name == "new")
        #expect(latest["j2"]?.name == "other")
        #expect(latest["j3"] == nil)
        #expect(latest.count == 2)
    }

    @Test("cron dTag prefix matches only its own job on delete")
    func cronDeleteIsolation() {
        // `arc/cron/j1/` prefix must never match `arc/cron/j2/…`.
        let d1 = TesseraCronStore.dTag(for: "j1", seq: 1)
        let d2 = TesseraCronStore.dTag(for: "j2", seq: 2)
        #expect(d1.hasPrefix("arc/cron/j1/") && !d1.hasPrefix("arc/cron/j2/"))
        #expect(d2.hasPrefix("arc/cron/j2/"))
    }

    // ── Goals ───────────────────────────────────────────────────────────

    @Test("goal dTag embeds session + sequence")
    func goalDTag() {
        #expect(TesseraGoalStore.dTag(for: "s1", seq: 3) == "arc/goals/s1/3")
    }

    @Test("latest goal record per session wins; malformed records are skipped")
    func goalLatestBySession() {
        func state(_ text: String) -> GoalState { GoalState(text: text) }
        let old = TesseraGoalRecord(seq: 1, sessionID: "s1", state: state("old"))
        let new = TesseraGoalRecord(seq: 9, sessionID: "s1", state: state("new"))
        let other = TesseraGoalRecord(seq: 2, sessionID: "s2", state: state("other"))

        func record(_ r: TesseraGoalRecord) -> TesseraRecord {
            TesseraRecord(
                id: nil,
                dTag: TesseraGoalStore.dTag(for: r.sessionID, seq: r.seq),
                content: String(decoding: try! JSONEncoder().encode(r), as: UTF8.self))
        }

        let latest = TesseraGoalStore.latestBySession(
            from: [record(old), record(other), record(new),
                   TesseraRecord(id: nil, dTag: "arc/goals/s3/1", content: "not json")])
        #expect(latest["s1"]?.text == "new")
        #expect(latest["s2"]?.text == "other")
        #expect(latest["s3"] == nil)
        #expect(latest.count == 2)
    }

    // ── GoalStoring protocol (file backend) ─────────────────────────────

    @Test("GoalStore conforms and round-trips through the protocol")
    func goalStoringRoundTrip() async throws {
        let store: any GoalStoring = try GoalStore()
        var goal = GoalState(text: "Harden the gateway")
        goal.contract = GoalContract(outcome: "tests pass", verification: "swift test")
        try await store.set(sessionID: "sess-A", state: goal)

        let loaded = try await store.get(sessionID: "sess-A")
        #expect(loaded?.text == "Harden the gateway")
        #expect(loaded?.contract?.verification == "swift test")

        try await store.update(sessionID: "sess-A") { $0.status = .paused }
        let paused = try await store.get(sessionID: "sess-A")
        #expect(paused?.status == .paused)

        try await store.clear(sessionID: "sess-A")
        let gone = try await store.get(sessionID: "sess-A")
        #expect(gone == nil)

        // `all()` reflects what `set` wrote.
        var goal2 = GoalState(text: "Second")
        try await store.set(sessionID: "sess-B", state: goal2)
        let everything = try await store.all()
        #expect(everything["sess-B"]?.text == "Second")
        _ = goal2
    }
}
