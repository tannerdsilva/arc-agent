import ArcToolKit
import Foundation

// MARK: - ProfileStore
//
// One job: persist and return the roster. It decides nothing.
//
// The port exists so that "who writes `index.json`" has exactly one answer
// per backend. Before it, every `ProfileManager()` held its own cache and did
// its own read-modify-write on one `index.json` with no cross-instance lock:
// 19 independent writers, each able to overwrite another's entry. The rule
// this port makes unrepresentable is *a roster mutation that does not go
// through the single writer for that backend*.
//
// Validation, duplicate refusal, `notFound`, and `cannotDeleteDefault` are
// caller decisions — the shim and the roster tools keep them. The store only
// stores: `put` is create-or-replace, `delete` is idempotent.

/// The roster, as a persistence port.
///
/// Conformances:
/// - ``FileProfileStore`` — `index.json` plus `profiles/<name>/config.json`
/// - ``TesseraProfileStore`` — kind-3004 events (`arc/p/<name>/<seq>`), with
///   the JSON index as the degraded path
/// - `InMemoryProfileStore` (tests) — the double that makes the single-writer
///   rule testable without a filesystem
///
/// Every requirement is `async` because two of the three backends are:
/// the file store serializes through its actor, the Tessera store awaits the
/// shared connection.
public protocol ProfileStore: Sendable {

    /// Every record in the roster, newest first.
    func list() async throws -> [Profile]

    /// The record for `name`, or `nil` when the roster has none.
    func get(_ name: ProfileName) async throws -> Profile?

    /// Create-or-replace `profile`; the store owns the index write.
    func put(_ profile: Profile) async throws

    /// Remove `name` and its profile directory. Idempotent: removing a name
    /// the roster does not hold is not an error (the caller decides whether
    /// that is `notFound`).
    func delete(_ name: ProfileName) async throws
}
