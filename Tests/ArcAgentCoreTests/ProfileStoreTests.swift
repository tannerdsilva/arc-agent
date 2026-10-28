import Testing
@testable import ArcAgentCore
import Foundation
import Logging
import ServiceLifecycle

extension ArcCoreTestRoot {

    /// The roster port and its conformers (GROUNDZERO slice 3).
    @Suite("Profile store")
    struct ProfileStoreTests {

        // MARK: - Fixtures

        /// Run `body` against an isolated profile root, restoring the seam and
        /// removing the root afterwards.
        private func withTempRoot(_ body: (String) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-profile-store-\(UUID().uuidString)", isDirectory: true)
            ProfileManager.testProfilesRoot = root.path
            defer {
                ProfileManager.testProfilesRoot = nil
                try? FileManager.default.removeItem(at: root)
            }
            try await body(root.path)
        }

        /// The roster as the test drives it — whichever implementation is
        /// under test. Same three operations, same names.
        private struct RosterDriver: Sendable {
            let create: @Sendable (String) async throws -> Void
            let delete: @Sendable (String) async throws -> Void
            let list: @Sendable () async throws -> [Profile]
        }

        /// What a concurrent run lost.
        private struct StressOutcome {
            /// Creates whose record is absent from the final roster.
            var missingCreates: [String] = []
            /// Deletes that the final roster still shows.
            var resurrectedDeletes: [String] = []
            /// Mutations that threw (a `notFound` from a clobbered index).
            var errors: [String] = []

            /// Entries the roster lost: either a create that vanished or a
            /// delete that came back.
            var lost: Int { missingCreates.count + resurrectedDeletes.count }

            var summary: String {
                "lost=\(lost) (missingCreates=\(missingCreates.count), "
                    + "resurrectedDeletes=\(resurrectedDeletes.count), errors=\(errors.count))"
            }
        }

        /// `tasks` concurrent tasks, each creating its own distinct profile and
        /// deleting its own distinct pre-seeded one. The end state is known
        /// exactly: `default` plus every `new-*`, and no `victim-*`.
        private func stress(
            _ driver: RosterDriver,
            tasks: Int,
            root: String
        ) async throws -> StressOutcome {
            // Pre-seed serially: a lost seed would muddy the measurement.
            for i in 0..<tasks {
                try await driver.create("victim-\(i)")
            }

            var outcome = StressOutcome()
            await withTaskGroup(of: String?.self) { group in
                for i in 0..<tasks {
                    group.addTask {
                        do {
                            try await driver.create("new-\(i)")
                            try await driver.delete("victim-\(i)")
                            return nil
                        } catch {
                            return "task \(i): \(error)"
                        }
                    }
                }
                for await failure in group {
                    if let failure { outcome.errors.append(failure) }
                }
            }

            let final = try await driver.list()
            let names = Set(final.map(\.name))
            for i in 0..<tasks where !names.contains("new-\(i)") {
                outcome.missingCreates.append("new-\(i)")
            }
            for i in 0..<tasks where names.contains("victim-\(i)") {
                outcome.resurrectedDeletes.append("victim-\(i)")
            }

            // The index must still be a parseable roster, whatever it holds.
            let indexPath = URL(fileURLWithPath: root).appendingPathComponent("index.json")
            let data = try Data(contentsOf: indexPath)
            _ = try JSONDecoder().decode([String: Profile].self, from: data)

            return outcome
        }

        /// Wrap a literal this suite knows is valid.
        private func name(_ raw: String) -> ProfileName {
            ProfileName(raw)!
        }

        // MARK: - The single writer

        /// RED before this slice: 32 independent `ProfileManager` instances,
        /// each doing its own read-modify-write on one `index.json`, lose
        /// entries. Green after: one ``ProfileService`` over one
        /// ``FileProfileStore`` serializes every mutation, so the final roster
        /// is exactly the expected set and the index still parses.
        @Test("concurrent roster mutations keep one index")
        func concurrentRosterMutationsKeepOneIndex() async throws {
            try await withTempRoot { root in
                let service = ProfileService(store: FileProfileStore(root: root))
                let driver = RosterDriver(
                    create: { name in try await service.put(Profile(name: name)) },
                    delete: { name in try await service.delete(ProfileName(name)!) },
                    list: { try await service.list() }
                )

                let tasks = 32
                let outcome = try await stress(driver, tasks: tasks, root: root)
                #expect(outcome.lost == 0, "\(outcome.summary)")
                #expect(outcome.errors.isEmpty, "\(outcome.errors)")

                let final = try await driver.list()
                let names = Set(final.map(\.name))
                var expected: Set<String> = ["default"]
                for i in 0..<tasks { expected.insert("new-\(i)") }
                #expect(names == expected)
            }
        }

        // MARK: - FileProfileStore

        @Test("put then get round-trips a record")
        func putThenGetRoundTrips() async throws {
            try await withTempRoot { root in
                let store = FileProfileStore(root: root)
                var profile = Profile(name: "prod", title: "Prod")
                profile.model = "gpt-5"
                try await store.put(profile)

                let loaded = try await store.get(name("prod"))
                #expect(loaded?.title == "Prod")
                #expect(loaded?.model == "gpt-5")
                #expect(FileManager.default.fileExists(atPath: "\(root)/prod/config.json"))
            }
        }

        @Test("get returns nil for an unknown profile")
        func getReturnsNilForMissingProfile() async throws {
            try await withTempRoot { root in
                let store = FileProfileStore(root: root)
                let loaded = try await store.get(name("ghost"))
                #expect(loaded == nil)
            }
        }

        @Test("put replaces an existing record in place")
        func putReplacesExistingRecord() async throws {
            try await withTempRoot { root in
                let store = FileProfileStore(root: root)
                try await store.put(Profile(name: "prod", title: "One"))
                try await store.put(Profile(name: "prod", title: "Two"))

                let all = try await store.list()
                #expect(all.filter { $0.name == "prod" }.count == 1)

                let loaded = try await store.get(name("prod"))
                #expect(loaded?.title == "Two")
            }
        }

        @Test("delete removes the record and its directory")
        func deleteRemovesRecordAndDirectory() async throws {
            try await withTempRoot { root in
                let store = FileProfileStore(root: root)
                try await store.put(Profile(name: "prod"))
                #expect(FileManager.default.fileExists(atPath: "\(root)/prod/config.json"))

                try await store.delete(name("prod"))
                let gone = try await store.get(name("prod"))
                #expect(gone == nil)
                #expect(!FileManager.default.fileExists(atPath: "\(root)/prod"))

                // Idempotent: deleting it again is not an error.
                try await store.delete(name("prod"))
            }
        }

        @Test("config.json wins over a stale index entry")
        func configJSONWinsOverIndexEntry() async throws {
            try await withTempRoot { root in
                let store = FileProfileStore(root: root)
                var profile = Profile(name: "prod", title: "Prod")
                profile.model = "gpt-5"
                profile.baseURL = "https://index.example/v1"
                try await store.put(profile)

                // Hand-edit the authoritative record, as a user would.
                let configURL = URL(fileURLWithPath: "\(root)/prod/config.json")
                var cfg = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: configURL))
                cfg.model = "gpt-9"
                cfg.baseURL = "https://hand-edited.example/v1"
                try JSONEncoder().encode(cfg).write(to: configURL, options: .atomic)

                let loaded = try await store.get(name("prod"))
                #expect(loaded?.model == "gpt-9")
                #expect(loaded?.baseURL == "https://hand-edited.example/v1")

                let all = try await store.list()
                let listed = all.first { $0.name == "prod" }
                #expect(listed?.model == "gpt-9")
            }
        }

        @Test("the default profile exists on first access")
        func defaultProfileIsSeededOnFirstAccess() async throws {
            try await withTempRoot { root in
                let store = FileProfileStore(root: root)
                let all = try await store.list()
                #expect(all.map(\.name) == ["default"])

                let seeded = try await store.get(name("default"))
                #expect(seeded?.title == "ARC Agent")
            }
        }

        @Test("the shim writes through the shared store")
        func shimWritesThroughTheSharedStore() async throws {
            try await withTempRoot { root in
                let manager = ProfileManager()
                var created = try await manager.create(name: "prod")
                created.title = "Prod"
                try await manager.update(created)

                // Both halves of the file format are on disk.
                #expect(FileManager.default.fileExists(atPath: "\(root)/prod/config.json"))
                #expect(FileManager.default.fileExists(atPath: "\(root)/index.json"))

                // A fresh reader over the same root sees the record.
                let store = FileProfileStore(root: root)
                let seen = try await store.get(name("prod"))
                #expect(seen?.title == "Prod")
            }
        }

        // MARK: - TesseraProfileStore

        /// The existing seam (`testProfilesRoot`) forces the file path, so the
        /// Tessera branch cannot be exercised without a live tunnel. What is
        /// reachable — and what a machine without Tessera actually runs — is
        /// the degradation: the same roster, through the JSON index, under the
        /// same contract.
        @Test("the tessera store degrades to the index without a tunnel")
        func tesseraStoreFallsBackToTheIndex() async throws {
            try await withTempRoot { root in
                let store = TesseraProfileStore(root: root)
                try await store.put(Profile(name: "prod", title: "Prod"))

                #expect(FileManager.default.fileExists(atPath: "\(root)/prod/config.json"))
                let loaded = try await store.get(name("prod"))
                #expect(loaded?.title == "Prod")

                // A second, file-backed reader sees the same record.
                let fileStore = FileProfileStore(root: root)
                let seen = try await fileStore.get(name("prod"))
                #expect(seen != nil)

                try await store.delete(name("prod"))

                // Assert against the file itself: a second store instance is a
                // second cache, and the contract here is one store per process.
                let indexURL = URL(fileURLWithPath: "\(root)/index.json")
                let indexData = try Data(contentsOf: indexURL)
                let index = try JSONDecoder().decode([String: Profile].self, from: indexData)
                #expect(index["prod"] == nil)
                #expect(!FileManager.default.fileExists(atPath: "\(root)/prod"))
            }
        }

        // MARK: - InMemoryProfileStore

        @Test("the in-memory store stands in for the file store")
        func inMemoryStoreStandsInForTheFileStore() async throws {
            let store = InMemoryProfileStore()
            let service = ProfileService(store: store)

            try await service.put(Profile(name: "prod", title: "Prod"))
            let loaded = try await service.get(name("prod"))
            #expect(loaded?.title == "Prod")

            let listed = try await service.list()
            #expect(listed.map(\.name).contains("prod"))

            try await service.delete(name("prod"))
            let gone = try await service.get(name("prod"))
            #expect(gone == nil)

            let deletes = await store.deleteCount
            let writes = await store.putCount
            #expect(deletes == 1)
            #expect(writes == 1)
        }

        @Test("one service, one backend, 32 concurrent writers")
        func serviceSerializesAgainstOneBackend() async throws {
            let store = InMemoryProfileStore()
            let service = ProfileService(store: store)

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<32 {
                    group.addTask {
                        try? await service.put(Profile(name: "p-\(i)"))
                    }
                }
            }

            let final = try await service.list()
            let names = Set(final.map(\.name))
            var expected: Set<String> = ["default"]
            for i in 0..<32 { expected.insert("p-\(i)") }
            #expect(names == expected)

            let writes = await store.putCount
            #expect(writes == 32)
        }

        // MARK: - Service lifetime

        /// Records that the enclosing `run()` returned.
        private actor ExitFlag {
            private(set) var exited = false
            func markExited() { exited = true }
        }

        /// Second Law: `run()` is the service's lifetime. It must not return
        /// until the group shuts down — a service that returned early would end
        /// the whole group at boot.
        @Test("the service lives until the group shuts down")
        func serviceLivesUntilTheGroupShutsDown() async throws {
            let flag = ExitFlag()
            let service = ProfileService(store: InMemoryProfileStore())
            let group = ServiceGroup(
                configuration: ServiceGroupConfiguration(
                    services: [service],
                    logger: Logger(label: "test.profile-service")
                )
            )

            let groupTask = Task {
                try await group.run()
                await flag.markExited()
            }

            // Give a wrong `run()` time to return.
            try await Task.sleep(for: .milliseconds(100))
            let exitedEarly = await flag.exited
            #expect(!exitedEarly, "ProfileService.run() returned before shutdown")

            await group.triggerGracefulShutdown()
            try await groupTask.value
            let exited = await flag.exited
            #expect(exited)
        }
    }
}
