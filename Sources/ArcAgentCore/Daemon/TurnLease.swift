import Foundation

/// A single-flight per-session turn lease.
///
/// Only one agent may be generating a response for a session at a time. In the
/// shared-session architecture the **owner's** agent is the only one that runs
/// turns, so this guard exists to stop the owner's own agent (or the gateway's
/// web-UI + CLI surfaces) from launching two concurrent turns on the same
/// session — e.g. a user sending two messages quickly, or two contributors'
/// message events landing back-to-back on one host.
///
/// In-process by design: cross-process coordination is unnecessary because the
/// owner is the sole turn runner; a sharee simply never runs a turn (it
/// contributes a message the owner's agent picks up).
public actor TurnLeaseRegistry {
    public static let shared = TurnLeaseRegistry()
    init() {}

    private var held: [String: Date] = [:]

    /// Try to acquire the lease for a session. Returns false if a live lease is
    /// already held for that session.
    public func acquire(sessionID: String, ttl: TimeInterval = 600) -> Bool {
        if let until = held[sessionID], until > Date() { return false }
        held[sessionID] = Date().addingTimeInterval(ttl)
        return true
    }

    /// Release the lease for a session.
    public func release(sessionID: String) {
        held[sessionID] = nil
    }

    /// Whether a live lease is currently held for a session.
    public func isHeld(sessionID: String) -> Bool {
        (held[sessionID] ?? .distantPast) > Date()
    }

    /// Number of live-held leases (observability/testing).
    public var liveCount: Int {
        held.values.filter { $0 > Date() }.count
    }
}
