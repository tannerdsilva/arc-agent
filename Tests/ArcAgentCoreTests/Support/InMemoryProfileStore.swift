import ArcToolKit
import Foundation

@testable import ArcAgentCore

// MARK: - InMemoryProfileStore

/// The third ``ProfileStore`` conformer: the roster without a filesystem.
///
/// This is not decoration. It is the seam that makes the single-writer rule
/// *testable*: a test can hand one `InMemoryProfileStore` to one
/// ``ProfileService`` and prove the service routes every mutation through the
/// one backend, and it can hand a recorder to a tool to prove a create is one
/// write (slice 5's `createIsOneWrite`) without touching `index.json`.
///
/// It is also the answer to "why is this a port rather than an actor?" — a
/// protocol with one production conformer and no test double usually means the
/// abstraction was speculative. Three conformers with different storage
/// behaviour (file, Tessera, memory) mean the port is carrying its weight.
actor InMemoryProfileStore: ProfileStore {

    private var records: [String: Profile] = [:]

    /// Number of `put` calls observed. A write recorder for the roster tools:
    /// a create that saves then updates is two writes, and the count says so.
    private(set) var putCount = 0

    /// Number of `delete` calls observed.
    private(set) var deleteCount = 0

    /// Seed the roster. The `default` profile is created on first access, as
    /// the file store does, so a test that asserts on the whole roster sees the
    /// same starting point in both backends.
    init(_ seed: [Profile] = []) {
        for profile in seed {
            records[profile.name] = profile
        }
    }

    // MARK: - ProfileStore

    func list() async throws -> [Profile] {
        seedDefaultIfNeeded()
        return records.values.sorted { $0.createdAt > $1.createdAt }
    }

    func get(_ name: ProfileName) async throws -> Profile? {
        seedDefaultIfNeeded()
        return records[name.rawValue]
    }

    func put(_ profile: Profile) async throws {
        putCount += 1
        records[profile.name] = profile
    }

    func delete(_ name: ProfileName) async throws {
        deleteCount += 1
        records.removeValue(forKey: name.rawValue)
    }

    // MARK: - Inspection

    /// Every record, unordered — for asserting on the store's contents without
    /// going through the port under test.
    var snapshot: [Profile] {
        Array(records.values)
    }

    private func seedDefaultIfNeeded() {
        guard records["default"] == nil else { return }
        records["default"] = Profile(
            name: "default",
            title: "ARC Agent",
            description: "The primary agent."
        )
    }
}
