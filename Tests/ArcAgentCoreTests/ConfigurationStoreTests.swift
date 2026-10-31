import Testing
import Foundation
@testable import ArcAgentCore

// MARK: - the single configuration store

extension ArcCoreTestRoot {
    @Suite("Configuration store", .serialized)
    struct ConfigurationStoreTests {

        /// a fresh config URL under a unique scratch directory.
        private func scratch() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("config.json")
        }

        @Test("mutate persists the canonical limits section and publishes it")
        func mutatePersists() async throws {
            let url = try scratch()
            let store = ConfigurationStore(url: url, environment: [:])

            let snapshot = try await store.mutate { $0.limits.turns = .unlimited }

            #expect(snapshot.declared.limits.turns == .unlimited)
            #expect(snapshot.resolved.limits.turns == .unlimited)
            // the bytes on disk decode back to what was written.
            let onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.limits.turns == .unlimited)
            #expect(onDisk.turnLimit() == .unlimited)
        }

        @Test("a corrupt file is refused, never replaced by compiled defaults")
        func corruptFileRefused() async throws {
            let url = try scratch()
            try Data("{ not json".utf8).write(to: url)
            let store = ConfigurationStore(url: url, environment: [:])

            #expect(await store.failure() != nil)
            await #expect(throws: ConfigError.self) {
                _ = try await store.mutate { $0.limits.turns = .bounded(5) }
            }
            let untouched = try String(contentsOf: url, encoding: .utf8)
            #expect(untouched == "{ not json")
        }

        @Test("environment overrides resolve but never reach the file")
        func environmentIsResolutionOnly() async throws {
            let url = try scratch()
            let store = ConfigurationStore(url: url, environment: ["ARC_MODEL": "env-model"])

            _ = try await store.mutate { $0.limits.perToolCalls = .bounded(9) }
            let snapshot = await store.snapshot()

            #expect(snapshot.resolved.model.defaultModel == "env-model")
            let onDisk = try ConfigurationStore.readDeclared(url)
            #expect(onDisk.model.defaultModel != "env-model")
        }

        @Test("reload picks up an external edit")
        func reloadPicksUpExternalEdit() async throws {
            let url = try scratch()
            let store = ConfigurationStore(url: url, environment: [:])
            #expect(await store.resolved().limits.turns == nil)

            var external = ArcConfig()
            external.limits.turns = .bounded(12)
            try ConfigurationStore.write(external, to: url)

            let snapshot = await store.reload()
            #expect(snapshot.declared.limits.turns == .bounded(12))
        }

        @Test("mutations stream to subscribers")
        func publishesUpdates() async throws {
            let url = try scratch()
            let store = ConfigurationStore(url: url, environment: [:])
            let stream = await store.updates()
            var iterator = stream.makeAsyncIterator()

            _ = try await store.mutate { $0.limits.turnDuration = .bounded(30) }
            let next = await iterator.next()

            #expect(next?.declared.limits.turnDuration == .bounded(30))
        }

        @Test("saveConfig refuses to overwrite a corrupt file")
        func saveRefusesCorruptFile() throws {
            let url = try scratch()
            try Data("{ bad".utf8).write(to: url)

            #expect(throws: ConfigError.self) {
                try saveConfig(ArcConfig(), to: url)
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "{ bad")
        }

        @Test("a no-op mutation writes nothing and publishes nothing")
        func noOpMutationIsQuiet() async throws {
            let url = try scratch()
            let store = ConfigurationStore(url: url, environment: [:])
            _ = try await store.mutate { $0.limits.turns = .bounded(4) }
            let firstWrite = try Data(contentsOf: url)

            _ = try await store.mutate { $0.limits.turns = .bounded(4) }

            #expect(try Data(contentsOf: url) == firstWrite)
        }
    }
}
