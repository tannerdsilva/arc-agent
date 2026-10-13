import Foundation
import Testing

import ArcAgentCore
import ArcWebUI

/// The phase-2 convergence: legacy `settings.json` scheduled jobs land in the
/// cron store exactly once, and a later deletion is never resurrected.
@Suite("Scheduled jobs import")
struct ScheduledJobsImportTests {

    private func writeSettings(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-cron-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func tempStore() -> FileCronStore {
        FileCronStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-cron-store-\(UUID().uuidString)", isDirectory: true))
    }

    private struct Legacy: Encodable {
        let theme: String
        let scheduledJobs: [CronJob]
    }

    @Test("legacy jobs move into the store and the key is dropped")
    func importMovesJobs() async throws {
        let job = CronJob(name: "digest", schedule: "every 15m", prompt: "summarize")
        let encoded = try JSONEncoder().encode(Legacy(theme: "dark", scheduledJobs: [job]))
        let url = try writeSettings(String(decoding: encoded, as: UTF8.self))
        let store = tempStore()

        await ScheduledJobsImport.runIfNeeded(into: store, settingsURL: url)

        let listed = try await store.listAll()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "digest")

        // the key is gone from the file (so a second run is a no-op) and the
        // rest of the settings survived the rewrite.
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("scheduledJobs"))
        #expect(raw.contains("dark"))
        await ScheduledJobsImport.runIfNeeded(into: store, settingsURL: url)
        #expect(try await store.listAll().count == 1)
    }

    @Test("a job deleted from the store is never resurrected")
    func deletionSticks() async throws {
        let job = CronJob(name: "once", schedule: "every 1h", prompt: "run once")
        let encoded = try JSONEncoder().encode(Legacy(theme: "light", scheduledJobs: [job]))
        let url = try writeSettings(String(decoding: encoded, as: UTF8.self))
        let store = tempStore()

        await ScheduledJobsImport.runIfNeeded(into: store, settingsURL: url)
        #expect(try await store.listAll().count == 1)

        try await store.delete(id: job.id)
        await ScheduledJobsImport.runIfNeeded(into: store, settingsURL: url)
        #expect(try await store.listAll().isEmpty)
    }

    @Test("a settings file with no legacy key is untouched")
    func absentKeyIsNoop() async throws {
        let url = try writeSettings(#"{"theme":"light"}"#)
        let store = tempStore()
        await ScheduledJobsImport.runIfNeeded(into: store, settingsURL: url)
        #expect(try await store.listAll().isEmpty)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("light"))
    }
}