import Foundation

/// The access role a user holds on a shared session.
public enum ShareRole: String, Codable, Sendable, Equatable, CaseIterable {
    /// View the transcript only.
    case read
    /// View + append user messages (turns are run by the owner's agent).
    case contribute
}

/// One granted user on a shared session.
public struct ShareGrantee: Codable, Sendable, Equatable {
    public var pubkey: String
    public var role: ShareRole
    public init(pubkey: String, role: ShareRole) {
        self.pubkey = pubkey
        self.role = role
    }
}

/// A share grant (kind 3007, d-tag `arc/share/<sessionID>/<seq>`).
///
/// The owner publishes one grant per shared session listing granted users. The
/// newest record for a session (selected by sequence number) is authoritative;
/// an empty `grantees` list is a revocation.
public struct TesseraShareGrant: Codable, Sendable, Equatable {
    public var seq: Int
    public var sessionID: String
    public var owner: String
    public var grantees: [ShareGrantee]

    public init(seq: Int, sessionID: String, owner: String, grantees: [ShareGrantee]) {
        self.seq = seq
        self.sessionID = sessionID
        self.owner = owner
        self.grantees = grantees
    }
}

/// Pure ACL resolution for shared sessions.
///
/// Side-effect free so it is trivially testable without a live tessera
/// connection: given the acting `identity`, a session (id + owner) and all
/// grants in play, decide the access role (or `nil` for no access).
public enum SharedSessionACL {

    /// The role `identity` holds on a session, or nil for no access.
    ///
    /// - A session with no owner (legacy) or whose owner equals `identity` is
    ///   owned ⇒ `contribute`.
    /// - Otherwise the newest grant naming `identity` for that session+owner
    ///   determines the role. An empty grant (revocation) grants nothing.
    public static func role(
        identity: String,
        sessionID: String,
        sessionOwner: String?,
        grants: [TesseraShareGrant]
    ) -> ShareRole? {
        if sessionOwner == nil || sessionOwner == identity { return .contribute }
        guard let grant = grants
            .filter({ $0.sessionID == sessionID && $0.owner == sessionOwner })
            .max(by: { $0.seq < $1.seq }) else {
            return nil
        }
        return grant.grantees.first(where: { $0.pubkey == identity })?.role
    }

    /// Whether `identity` is the session's OWNER (runs its turns). A session
    /// with no owner (legacy) is treated as owned by the current identity.
    public static func isOwner(_ identity: String, sessionOwner: String?) -> Bool {
        sessionOwner == nil || sessionOwner == identity
    }

    /// Whether the session is visible at all to `identity`.
    public static func isVisible(
        identity: String,
        sessionID: String,
        sessionOwner: String?,
        grants: [TesseraShareGrant]
    ) -> Bool {
        role(identity: identity, sessionID: sessionID, sessionOwner: sessionOwner, grants: grants) != nil
    }

    /// Whether `identity` may append messages (contribute/owner only).
    public static func canContribute(
        identity: String,
        sessionID: String,
        sessionOwner: String?,
        grants: [TesseraShareGrant]
    ) -> Bool {
        role(identity: identity, sessionID: sessionID, sessionOwner: sessionOwner, grants: grants) == .contribute
    }

    /// The newest grant governing `sessionID` (if any). Used by the share
    /// manager to show the current grantee set, and by callers that need the
    /// raw grant rather than just the resolved role.
    public static func grant(sessionID: String, owner: String?, grants: [TesseraShareGrant]) -> TesseraShareGrant? {
        guard let owner else { return nil }
        return grants
            .filter { $0.sessionID == sessionID && $0.owner == owner }
            .max(by: { $0.seq < $1.seq })
    }
}


/// A store for session share grants, backed by tessera kind-3007 events.
///
/// Grants are append-only like session metadata; the newest record per session
/// (by sequence number) is authoritative. An empty `grantees` list is a
/// revocation. `TesseraConnection.shared` is the single process-wide tunnel,
/// so in the shipped architecture each user runs their own process (and own
/// identity); two-user behaviour is exercised by the pure ``SharedSessionACL``.
public actor TesseraShareStore {
    public static let shared = TesseraShareStore()
    private init() {}
    private var connection: TesseraConnection { TesseraConnection.shared }

    /// Publish (or replace) a grant for a shared session.
    public func grant(sessionID: String, owner: String, grantees: [ShareGrantee]) async throws {
        let conn = connection
        try await conn.ensureStarted()
        let seq = await conn.takeSequence()
        let grant = TesseraShareGrant(seq: seq, sessionID: sessionID, owner: owner, grantees: grantees)
        try await publish(grant)
    }

    /// Revoke every grant for a session (deletes its kind-3007 events).
    public func revoke(sessionID: String) async throws {
        let conn = connection
        try await conn.ensureStarted()
        try await conn.deleteAll(dTagPrefix: "arc/share/\(sessionID)/", kind: TesseraConnection.shareKind)
    }

    /// All latest (per-session) grants.
    public func latestGrants() async -> [TesseraShareGrant] {
        let conn = connection
        var latest: [String: TesseraShareGrant] = [:]   // key: sessionID
        for rec in await conn.snapshot(kind: TesseraConnection.shareKind) {
            guard let g = try? JSONDecoder().decode(TesseraShareGrant.self, from: Data(rec.content.utf8)) else {
                continue
            }
            if let cur = latest[g.sessionID], cur.seq >= g.seq { continue }
            latest[g.sessionID] = g
        }
        return Array(latest.values)
    }

    /// The role `identity` holds on a session (nil = no access).
    public func role(identity: String, sessionID: String, sessionOwner: String?) async -> ShareRole? {
        let grants = await latestGrants()
        return SharedSessionACL.role(identity: identity, sessionID: sessionID, sessionOwner: sessionOwner, grants: grants)
    }

    private func publish(_ grant: TesseraShareGrant) async throws {
        let content = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        try await connection.publish(
            kind: TesseraConnection.shareKind,
            dTagValue: "arc/share/\(grant.sessionID)/\(grant.seq)",
            content: content
        )
    }
}


/// Errors raised by the shared-session access layer.
public enum SessionShareError: Error, Equatable, Sendable {
    /// The acting identity may not append to this session (role < contribute).
    case notAuthorized
    /// The acting identity may not modify the session (not the owner).
    case notOwner
}
