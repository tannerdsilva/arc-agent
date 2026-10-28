import Foundation
import ServiceLifecycle

// MARK: - ProfileService

/// The process's one roster writer.
///
/// **Isolation boundary, in one sentence:** ``ProfileService`` serializes every
/// roster mutation against exactly one ``ProfileStore`` backend, so no second
/// caller can read-modify-write the same index underneath it.
///
/// Before this actor, `ProfileManager()` was constructed 19 times — tools, the
/// session host, the CLI, the web UI — each instance an independent actor with
/// its own cache doing its own read-modify-write on `index.json` with no
/// cross-instance lock. The roster's writer count is now one per process, and
/// that writer is a `Service` in the daemon's tree (Second Law: it has an
/// owner and a lifetime, instead of being spawned per call site).
///
/// Residency: process-wide, one `Service` in the `ServiceGroup` (GROUNDZERO
/// §7). It is not per turn and not per agent.
///
/// This type decides nothing. Validation, duplicate refusal, `notFound`, and
/// `cannotDeleteDefault` stay with the caller that already owns those rules.
public actor ProfileService: Service {

    /// The single backend. Private: reaching around the service would restore
    /// the second-writer problem the port exists to remove.
    private let store: any ProfileStore

    /// Wrap `store` — the process has exactly one of these for its lifetime.
    ///
    /// The default is the process-wide ``TesseraProfileStore/shared``, which
    /// degrades to the JSON index when Tessera is unconfigured — exactly what
    /// `ProfileManager` did per operation. `ProfileManager()` shims delegate to
    /// the same instance, so today's 19 call sites already write through one
    /// store; the service adds the owned lifetime, not a second writer.
    public init(store: any ProfileStore = TesseraProfileStore.shared) {
        self.store = store
    }

    // MARK: - Roster

    /// Every record, newest first.
    public func list() async throws -> [Profile] {
        try await store.list()
    }

    /// The record for `name`, or `nil`.
    public func get(_ name: ProfileName) async throws -> Profile? {
        try await store.get(name)
    }

    /// Create-or-replace `profile`.
    public func put(_ profile: Profile) async throws {
        try await store.put(profile)
    }

    /// Remove `name` and its profile directory.
    public func delete(_ name: ProfileName) async throws {
        try await store.delete(name)
    }

    // MARK: - Service

    /// The service's lifetime.
    ///
    /// `run()` does not return until the group shuts down; teardown belongs
    /// here, not in a caller's `defer` (Second Law). No store in this slice
    /// owns a flushed resource — every mutation is already an atomic write and
    /// the Tessera connection is process-owned — so the tail below releases
    /// the roster handle rather than flushing it. A store that later gains a
    /// connection or a temp file closes it at this point.
    public func run() async throws {
        do {
            try await gracefulShutdown()
        } catch is CancellationError {
            // Expected: cancelled directly rather than by group shutdown.
        }
    }
}

// MARK: - ProfileStore
//
// The service is a store-shaped façade over the one backend it owns, so a
// caller that was handed the service (the daemon's ``SessionRegistry/AgentConfig``)
// can hand it straight to `buildRegistry(profiles:)` — no second store, no
// second cache, no reach-around to the private backend. The four requirements
// above are already implemented; this only declares the relationship.
extension ProfileService: ProfileStore {}
