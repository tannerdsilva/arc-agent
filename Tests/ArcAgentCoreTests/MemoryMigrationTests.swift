import Testing
@testable import ArcAgentCore
import Foundation

// MARK: - Memory relocation (GROUNDZERO slice 5, ledger D15)
//
// Slice 4 re-rooted every memory provider at `~/.arc/profiles/<name>/`, which
// left the old global pair (`~/.arc/memories/MEMORY.md` / `USER.md`) read by
// nothing. For an install that predates that change, that is silent loss.
//
// The seed must therefore be three things at once, and each test is the monitor
// for one: it copies what is missing, it never overwrites a document a profile
// already owns, and it runs once — so a profile created later inherits nothing
// from whoever used the machine before.
extension ArcCoreTestRoot {

    @Suite("Memory migration")
    struct MemoryMigrationTests {

        // MARK: - Fixture

        struct Fixture {
            let root: URL
            let legacy: URL
            let profiles: URL
            let marker: URL
        }

        private func makeFixture() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-memory-migration-\(UUID().uuidString)", isDirectory: true)
            let legacy = root.appendingPathComponent("memories", isDirectory: true)
            let profiles = root.appendingPathComponent("profiles", isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
            return Fixture(
                root: root,
                legacy: legacy,
                profiles: profiles,
                marker: root.appendingPathComponent(".memory-migration-v1")
            )
        }

        private func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        private func read(_ url: URL) -> String? {
            try? String(contentsOf: url, encoding: .utf8)
        }

        /// The roster every test starts from: the legacy memory belonged to the
        /// machine's primary agent, so `default` is a recipient too.
        private func roster() -> InMemoryProfileStore {
            InMemoryProfileStore([
                Profile(name: "default"),
                Profile(name: "alice"),
                Profile(name: "bob"),
            ])
        }

        // MARK: - Tests

        /// Copies what is missing into every profile, leaves what exists alone,
        /// and logs one line per file it wrote.
        @Test("copies the legacy documents into profiles that lack them")
        func copiesMissingDocuments() async throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            try write("legacy memory", to: fixture.legacy.appendingPathComponent("MEMORY.md"))
            try write("legacy user", to: fixture.legacy.appendingPathComponent("USER.md"))
            // Alice already writes her own memory: her document wins.
            try write("alice own", to: fixture.profiles
                .appendingPathComponent("alice", isDirectory: true)
                .appendingPathComponent("MEMORY.md"))

            var lines: [String] = []
            let copied = await MemoryMigration.runIfNeeded(
                profiles: roster(),
                legacy: fixture.legacy,
                profilesRoot: fixture.profiles,
                marker: fixture.marker,
                log: { lines.append($0) }
            )

            // default + bob get both documents; alice gets only USER.md.
            #expect(copied.count == 5)
            #expect(lines.count == 5)
            #expect(lines.allSatisfy { $0.contains("memory migration: copied") })

            let bobMemory = fixture.profiles
                .appendingPathComponent("bob", isDirectory: true)
                .appendingPathComponent("MEMORY.md")
            #expect(read(bobMemory) == "legacy memory")
            let defaultUser = fixture.profiles
                .appendingPathComponent("default", isDirectory: true)
                .appendingPathComponent("USER.md")
            #expect(read(defaultUser) == "legacy user")

            // The existing document was skipped, not replaced.
            let aliceMemory = fixture.profiles
                .appendingPathComponent("alice", isDirectory: true)
                .appendingPathComponent("MEMORY.md")
            #expect(read(aliceMemory) == "alice own")
            // …and the missing one beside it was filled in.
            let aliceUser = fixture.profiles
                .appendingPathComponent("alice", isDirectory: true)
                .appendingPathComponent("USER.md")
            #expect(read(aliceUser) == "legacy user")

            #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
        }

        /// A second run copies nothing and says nothing.
        @Test("a second run is a no-op")
        func secondRunIsANoOp() async throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            try write("legacy memory", to: fixture.legacy.appendingPathComponent("MEMORY.md"))
            let store = roster()

            let first = await MemoryMigration.runIfNeeded(
                profiles: store, legacy: fixture.legacy,
                profilesRoot: fixture.profiles, marker: fixture.marker)
            #expect(first.count == 3)

            var lines: [String] = []
            let second = await MemoryMigration.runIfNeeded(
                profiles: store, legacy: fixture.legacy,
                profilesRoot: fixture.profiles, marker: fixture.marker,
                log: { lines.append($0) })
            #expect(second.isEmpty)
            #expect(lines.isEmpty)

            let bobMemory = fixture.profiles
                .appendingPathComponent("bob", isDirectory: true)
                .appendingPathComponent("MEMORY.md")
            #expect(read(bobMemory) == "legacy memory")
        }

        /// A profile created after the relocation starts empty. The legacy file
        /// is still on disk, so this is the marker doing its job — not an
        /// accident of the file having been moved away.
        @Test("a profile created after the relocation gets nothing")
        func laterProfilesGetNothing() async throws {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            try write("legacy memory", to: fixture.legacy.appendingPathComponent("MEMORY.md"))
            let store = roster()

            let first = await MemoryMigration.runIfNeeded(
                profiles: store, legacy: fixture.legacy,
                profilesRoot: fixture.profiles, marker: fixture.marker)
            #expect(first.count == 3)

            // A new profile joins the roster after the one-time seed.
            try await store.put(Profile(name: "carol"))
            #expect(FileManager.default.fileExists(
                atPath: fixture.legacy.appendingPathComponent("MEMORY.md").path))

            let second = await MemoryMigration.runIfNeeded(
                profiles: store, legacy: fixture.legacy,
                profilesRoot: fixture.profiles, marker: fixture.marker)
            #expect(second.isEmpty)
            let carolMemory = fixture.profiles
                .appendingPathComponent("carol", isDirectory: true)
                .appendingPathComponent("MEMORY.md")
            #expect(read(carolMemory) == nil)
        }
    }
}
