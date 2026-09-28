import Foundation

/// A cron job persisted as a Tessera event (kind 3005), mirroring the
/// session store's record shape: the payload is JSON in the event content,
/// and the event's `d` tag carries `arc/cron/<jobID>/<seq>`.
public struct TesseraCronRecord: Codable, Sendable, Equatable {
    /// The global sequence number of this event.
    public var seq: Int
    /// The job payload.
    public var job: CronJob

    public init(seq: Int, job: CronJob) {
        self.seq = seq
        self.job = job
    }
}

/// A ``CronStore`` backed by a Tessera server.
///
/// Jobs are stored as signed NOSTR events through the shared
/// ``TesseraConnection``:
///
/// - Jobs: kind 3005, `d` tag `arc/cron/<jobID>/<seq>`
///
/// Cache-first like ``FileCronStore``: the event snapshot is decoded once
/// (newest record per job wins), every write publishes a signed event and
/// updates the local cache. Deletion removes all events for that job id.
public actor TesseraCronStore: CronStore {

    public static let kind: UInt32 = 3_005

    private var connection: TesseraConnection { TesseraConnection.shared }

    private var cache: [String: CronJob] = [:]
    private var loaded = false

    public init() {}

    // MARK: - Helpers (exposed for unit tests)

    /// `d` tag value for a job event.
    public static func dTag(for jobID: String, seq: Int) -> String {
        "arc/cron/\(jobID)/\(seq)"
    }

    /// Decode a snapshot into the newest record per job id (highest seq wins).
    public static func latestByJob(from records: [TesseraRecord]) -> [String: CronJob] {
        var latest: [String: (seq: Int, job: CronJob)] = [:]
        for record in records {
            guard let dTag = record.dTag,
                  dTag.hasPrefix("arc/cron/"),
                  let seq = TesseraConnection.sequenceNumber(fromTagKey: dTag),
                  let decoded = try? JSONDecoder().decode(TesseraCronRecord.self, from: Data(record.content.utf8))
            else { continue }
            let id = decoded.job.id
            if let existing = latest[id], existing.seq >= seq { continue }
            latest[id] = (seq, decoded.job)
        }
        return latest.mapValues(\.job)
    }

    // MARK: - CronStore

    public func save(_ job: CronJob) async throws {
        try await ensureLoaded()
        let conn = connection
        try await conn.ensureStarted()
        let seq = await conn.takeSequence()
        let content = String(decoding: try JSONEncoder().encode(TesseraCronRecord(seq: seq, job: job)), as: UTF8.self)
        try await conn.publish(kind: Self.kind, dTagValue: Self.dTag(for: job.id, seq: seq), content: content)
        cache[job.id] = job
    }

    public func get(id: String) async throws -> CronJob? {
        try await ensureLoaded()
        return cache[id]
    }

    public func delete(id: String) async throws {
        try await ensureLoaded()
        let conn = connection
        try await conn.ensureStarted()
        try await conn.deleteAll(dTagPrefix: "arc/cron/\(id)/", kind: Self.kind)
        cache[id] = nil
    }

    public func listActive() async throws -> [CronJob] {
        try await ensureLoaded()
        return cache.values.filter { $0.isActive }
    }

    public func listAll() async throws -> [CronJob] {
        try await ensureLoaded()
        return Array(cache.values)
    }

    // MARK: - Private

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        let conn = connection
        try await conn.ensureStarted()
        cache = Self.latestByJob(from: await conn.snapshot(kind: Self.kind))
        loaded = true
    }
}
