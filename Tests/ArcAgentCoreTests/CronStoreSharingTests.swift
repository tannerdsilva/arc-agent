import Foundation
import Testing

import ArcAgentCore

/// `FileCronStore` is deliberately stateless: several processes share the
/// directory, so a job written through one store instance must be visible
/// through another immediately (a per-instance cache made it invisible until
/// restart — the bug this pins).
@Suite("Cron store sharing")
struct CronStoreSharingTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-cron-share-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("a save through one instance is visible through another")
    func crossInstanceVisibility() async throws {
        let dir = tempDir()
        let writer = FileCronStore(directory: dir)
        let reader = FileCronStore(directory: dir)

        let job = CronJob(name: "shared", schedule: "every 30m", prompt: "hello")
        try await writer.save(job)

        let listed = try await reader.listAll()
        #expect(listed.count == 1)
        #expect(listed.first?.id == job.id)
        #expect(try await reader.get(id: job.id)?.name == "shared")
    }

    @Test("a delete through one instance is visible through another")
    func crossInstanceDeletion() async throws {
        let dir = tempDir()
        let writer = FileCronStore(directory: dir)
        let reader = FileCronStore(directory: dir)

        let job = CronJob(name: "gone", schedule: "every 1h", prompt: "x")
        try await writer.save(job)
        #expect(try await reader.listAll().count == 1)

        try await writer.delete(id: job.id)
        #expect(try await reader.listAll().isEmpty)
        #expect(try await reader.get(id: job.id) == nil)
    }
}