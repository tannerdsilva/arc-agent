import Foundation

// MARK: - Job chaining (`context_from` parity, arc-shaped — plan Phase 8)
//
// Injection reads the UPSTREAM'S HISTORY RECORD (Phase 2), not its
// `lastOutput` — chained jobs see status + error text, not a 4 KB tail.
// And because the record is the upstream's plain output (never its own
// injected prompt), chains don't accumulate injection blocks transitively:
// A→B→C passes B's record into C, full stop.

public enum CronChaining {

    /// One resolved upstream contribution.
    public struct Upstream: Sendable {
        public let name: String
        public let record: CronRunRecord

        public init(name: String, record: CronRunRecord) {
            self.name = name
            self.record = record
        }
    }

    /// Build the firing prompt: for each referenced job, its latest
    /// `status == "ok"` record is prepended as a context block. A missing
    /// reference (job absent, or no successful run yet) contributes
    /// NOTHING — never block a firing on an unavailable upstream.
    ///
    /// The `resolve` closure is the medium seam: the runner supplies
    /// store+history lookups; tests supply stubs. Errored upstreams are
    /// skipped HERE (the resolver should return nil for them, matching
    /// "latest ok record" semantics).
    public static func injectedPrompt(
        base: String,
        contextFrom: [String],
        resolve: @Sendable (String) async -> Upstream?
    ) async -> String {
        guard !contextFrom.isEmpty else { return base }
        var blocks: [String] = []
        let formatter = ISO8601DateFormatter()
        for id in contextFrom {
            guard let upstream = await resolve(id) else { continue }
            let startedAt = formatter.string(from: upstream.record.startedAt)
            let block = "[Context from job \"\(upstream.name)\" (\(id)), "
                + "last successful run \(startedAt)]:\n\(upstream.record.output)"
            blocks.append(block)
        }
        guard !blocks.isEmpty else { return base }
        return blocks.joined(separator: "\n\n") + "\n\n" + base
    }

    /// Convenience resolver for runner closures: latest ok record from a
    /// history backend, named from the store. Nil on any absence (missing
    /// job, no successful run, history not wired).
    public static func makeResolver(
        store: any CronStore,
        history: any CronRunHistory
    ) -> @Sendable (String) async -> Upstream? {
        { id in
            guard let upstream = try? await store.get(id: id) else { return nil }
            // Newest-first; the first ok record is the latest success.
            let runs = (try? await history.listRuns(jobID: id, limit: 20)) ?? []
            guard let record = runs.first(where: { $0.status == "ok" || $0.status == nil }) else {
                return nil
            }
            return Upstream(name: upstream.name, record: record)
        }
    }
}
