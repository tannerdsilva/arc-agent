import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Job chaining (`context_from`) (plan Phase 8)
//
// Injection reads the upstream's latest OK record; errored and missing
// upstreams contribute nothing (a firing never blocks on an unavailable
// upstream). Chains don't accumulate: C reads B's RECORD — plain output,
// never B's injected prompt.

@Suite("Cron Chaining")
struct CronChainingTests {

    private let okA = CronRunRecord(jobID: "a", startedAt: Date(timeIntervalSince1970: 1_000),
                                    finishedAt: nil, status: "ok", output: "A ran", error: nil)
    private let okB = CronRunRecord(jobID: "b", startedAt: Date(timeIntervalSince1970: 2_000),
                                    finishedAt: nil, status: "ok", output: "B ran", error: nil)
    private let errB = CronRunRecord(jobID: "b", startedAt: Date(timeIntervalSince1970: 3_000),
                                     finishedAt: nil, status: "error", output: "Error: boom", error: "boom")

    private func resolver(_ table: [String: CronChaining.Upstream?])
        -> @Sendable (String) async -> CronChaining.Upstream? {
        { id in table[id] ?? nil }
    }

    @Test("referenced job's latest ok record is injected, with name and date")
    func injectsLatestOk() async {
        let prompt = await CronChaining.injectedPrompt(
            base: "do the thing",
            contextFrom: ["a"],
            resolve: resolver(["a": .init(name: "Alpha", record: okA),
                               "b": .init(name: "Beta", record: errB)])
        )
        #expect(prompt.contains("[Context from job \"Alpha\" (a),"))
        #expect(prompt.contains("A ran"))
        #expect(prompt.hasSuffix("do the thing"), "the job's own prompt stays last")
    }

    @Test("errored upstream is skipped, not injected")
    func erroredSkipped() async {
        // Resolver follows "latest ok" semantics: an upstream whose latest
        // runs are all errors resolves to nil.
        let prompt = await CronChaining.injectedPrompt(
            base: "do the thing",
            contextFrom: ["b"],
            resolve: resolver(["b": nil])  // no successful run
        )
        #expect(prompt == "do the thing", "missing/errored upstream contributes nothing")
    }

    @Test("missing upstream is skipped")
    func missingSkipped() async {
        let prompt = await CronChaining.injectedPrompt(
            base: "do the thing",
            contextFrom: ["ghost"],
            resolve: resolver([:])
        )
        #expect(prompt == "do the thing")
    }

    @Test("chains don't accumulate: C receives B's plain record output")
    func noTransitiveAccumulation() async {
        // B's record output is its RUN output — even though B itself
        // consumes A, its record contains only what B produced. C's
        // injection therefore carries B's output only, never A's block.
        let bRecord = CronRunRecord(jobID: "b", startedAt: Date(timeIntervalSince1970: 5_000),
                                    finishedAt: nil, status: "ok",
                                    output: "B ran (and says nothing about A)", error: nil)
        let prompt = await CronChaining.injectedPrompt(
            base: "C's turn",
            contextFrom: ["b"],
            resolve: resolver(["b": .init(name: "Beta", record: bRecord)])
        )
        #expect(prompt.contains("B ran (and says nothing about A)"))
        #expect(!prompt.contains("[Context from job \"Alpha\""),
                "no transitive injection blocks: \(prompt)")
    }

    @Test("empty contextFrom returns the base prompt untouched")
    func emptyNoop() async {
        let prompt = await CronChaining.injectedPrompt(base: "p", contextFrom: [], resolve: resolver([:]))
        #expect(prompt == "p")
    }

    @Test("the store-backed resolver returns the latest ok, skips errored, nil on missing")
    func storeResolver() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-chain-\(UUID().uuidString)", isDirectory: true)
        let store = FileCronStore(directory: dir)
        let history = FileCronRunHistory(directory: dir.appendingPathComponent("history", isDirectory: true))
        let a = CronJob(id: "a", name: "Alpha", schedule: "1h", prompt: "p")
        try await store.save(a)
        try await history.record(CronRunRecord(jobID: "a", startedAt: Date(timeIntervalSince1970: 10),
                                           finishedAt: nil, status: "error", output: "err", error: "e"),
                             jobID: "a")
        try await history.record(CronRunRecord(jobID: "a", startedAt: Date(timeIntervalSince1970: 20),
                                           finishedAt: nil, status: "ok", output: "good", error: nil),
                             jobID: "a")
        let resolve = CronChaining.makeResolver(store: store, history: history)
        let up = await resolve("a")
        #expect(up?.name == "Alpha")
        #expect(up?.record.output == "good", "latest ok, not the errored newer/older mix")
        #expect(await resolve("ghost") == nil)
    }
}
