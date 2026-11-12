import Foundation

/// A ``CronRunHistory`` backed by a Tessera server — with **no separate
/// write path**. The scheduler's single per-run `save(job)` *is* the
/// history write: the job payload carries `lastStatus`/`lastStartedAt`/
/// `lastFinishedAt`/`lastError`, so every kind-3005 event for a job is a
/// frozen snapshot of one attempt. ``record`` is therefore a documented
/// no-op and ``listRuns`` decodes the per-job event stream read-time —
/// retention is the read-time `limit`, never deletion (events are
/// append-only; `delete` removes all events for a job id).
public actor TesseraCronRunHistory: CronRunHistory {

    /// Same kind as the job store: history and job definitions share the
    /// event stream — that is the whole point of Option C.
    public static let kind: UInt32 = 3_005

    private var connection: TesseraConnection { TesseraConnection.shared }

    public init() {}

    // MARK: - CronRunHistory

    public func record(_ run: CronRunRecord, jobID: String) async throws {
        // Intentionally empty. In tessera mode the scheduler's single
        // `store.save(job)` publishes the run (single-save rule); a
        // `record` call here would be a second kind-3005 publish per run.
    }

    public func listRuns(jobID: String, limit: Int) async throws -> [CronRunRecord] {
        let conn = connection
        try await conn.ensureStarted()
        return Self.runs(from: await conn.snapshot(kind: Self.kind), jobID: jobID, limit: limit)
    }

    public func prune(jobID: String, keep: Int) async throws {
        // No-op: events are append-only and are never pruned. The
        // read-time `limit` bounds what surfaces render.
    }

    // MARK: - Decode (pure, exercised directly by tests)

    /// Derive one ``CronRunRecord`` per kind-3005 event for `jobID`,
    /// newest-seq-first, honoring `limit`. An event predating the status
    /// fields (old payload) decodes to a record with nil status rather
    /// than being dropped — a job's history never shrinks on upgrade.
    ///
    /// Multiple events can describe the SAME run (every save of the job
    /// publishes a snapshot; a save storm after a manual run used to
    /// duplicate rows). Events sharing a `startedAt` are one attempt —
    /// keep the highest seq (the most recent snapshot of that run).
    public static func runs(from records: [TesseraRecord], jobID: String, limit: Int) -> [CronRunRecord] {
        let prefix = "arc/cron/\(jobID)/"
        var runs: [(seq: Int, startedAt: Date, run: CronRunRecord)] = []
        for record in records {
            guard let dTag = record.dTag,
                  dTag.hasPrefix(prefix),
                  let seq = TesseraConnection.sequenceNumber(fromTagKey: dTag),
                  let payload = try? JSONDecoder().decode(TesseraCronRecord.self, from: Data(record.content.utf8))
            else { continue }
            let job = payload.job
            // A snapshot without lastStartedAt is not a run — it's a state
            // save (job creation, an edit, a pause). Rendering it as a run
            // produced a phantom "Dec 31, 1969 18:00" row (epoch zero in
            // local time). Snapshots only become run records once the
            // scheduler or a manual Run-now has stamped a start time.
            guard let startedAt = job.lastStartedAt else { continue }
            let run = CronRunRecord(
                jobID: jobID,
                startedAt: startedAt,
                finishedAt: job.lastFinishedAt,
                status: job.lastStatus,
                output: job.lastOutput ?? "",
                error: job.lastError
            )
            runs.append((seq, startedAt, run))
        }
        // same-run collapse: identical startedAt keeps the newest snapshot
        var deduped: [(seq: Int, startedAt: Date, run: CronRunRecord)] = []
        for entry in runs.sorted(by: { $0.seq < $1.seq }) {
            if let last = deduped.last, last.startedAt == entry.startedAt {
                deduped[deduped.count - 1] = entry
            } else {
                deduped.append(entry)
            }
        }
        return deduped.sorted { $0.seq > $1.seq }.prefix(limit).map(\.run)
    }
}
