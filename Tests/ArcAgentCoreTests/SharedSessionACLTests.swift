import Foundation
import Testing
@testable import ArcAgentCore

/// Tasks 2-4 — session ownership + share-grant ACL. The ACL resolution is pure,
/// so it is tested with injected identities (no live tessera connection), and
/// the owner field must survive both Session and TesseraSessionMeta round-trips.
@Suite("Shared session ACL")
struct SharedSessionACLTests {

    private let ownerA = "pubkeyA"
    private let ownerB = "pubkeyB"
    private let viewer = "pubkeyViewer"

    private func grant(_ sessionID: String, _ owner: String, _ grantees: [ShareGrantee], seq: Int = 1) -> TesseraShareGrant {
        TesseraShareGrant(seq: seq, sessionID: sessionID, owner: owner, grantees: grantees)
    }

    @Test("a session with no owner (legacy) is owned by the acting identity")
    func legacyOwned() {
        #expect(SharedSessionACL.role(identity: viewer, sessionID: "s1", sessionOwner: nil, grants: []) == .contribute)
        #expect(SharedSessionACL.isVisible(identity: viewer, sessionID: "s1", sessionOwner: nil, grants: []))
        // Phase 1 turn mode: a legacy (ownerless) session is a local host.
        #expect(SharedSessionACL.turnMode(identity: viewer, sessionID: "s1", sessionOwner: nil, grants: []) == .host)
    }

    @Test("a session owned by the acting identity is owned")
    func selfOwned() {
        let grants = [grant("s1", ownerA, [])]
        #expect(SharedSessionACL.role(identity: ownerA, sessionID: "s1", sessionOwner: ownerA, grants: grants) == .contribute)
        #expect(SharedSessionACL.canContribute(identity: ownerA, sessionID: "s1", sessionOwner: ownerA, grants: grants))
    }

    @Test("a granted contributor can contribute; is visible")
    func contributor() {
        let grants = [grant("s1", ownerA, [ShareGrantee(pubkey: viewer, role: .contribute)])]
        #expect(SharedSessionACL.role(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants) == .contribute)
        #expect(SharedSessionACL.canContribute(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants))
        #expect(SharedSessionACL.isVisible(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants))
    }

    @Test("a read-only grantee is visible but cannot contribute")
    func readOnly() {
        let grants = [grant("s1", ownerA, [ShareGrantee(pubkey: viewer, role: .read)])]
        #expect(SharedSessionACL.role(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants) == .read)
        #expect(!SharedSessionACL.canContribute(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants))
        #expect(SharedSessionACL.isVisible(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants))
    }

    @Test("an unrelated identity sees nothing")
    func unrelated() {
        let grants = [grant("s1", ownerA, [ShareGrantee(pubkey: viewer, role: .contribute)])]
        #expect(!SharedSessionACL.isVisible(identity: "stranger", sessionID: "s1", sessionOwner: ownerA, grants: grants))
        #expect(!SharedSessionACL.canContribute(identity: "stranger", sessionID: "s1", sessionOwner: ownerA, grants: grants))
        #expect(SharedSessionACL.role(identity: "stranger", sessionID: "s1", sessionOwner: ownerA, grants: grants) == nil)
    }

    @Test("an empty-grantee grant (revocation) grants nothing")
    func revoked() {
        let grants = [grant("s1", ownerA, [], seq: 2)]
        #expect(!SharedSessionACL.isVisible(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants))
    }

    // MARK: Phase 1 — host/guest turn mode

    @Test("turn mode: a contributing grantee is a guest (owner is sole host)")
    func turnModeContributor() {
        let grants = [grant("s1", ownerA, [ShareGrantee(pubkey: viewer, role: .contribute)])]
        #expect(SharedSessionACL.turnMode(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants) == .guest)
    }

    @Test("turn mode: a read-only grantee is still a guest (must not run turns)")
    func turnModeReadOnly() {
        let grants = [grant("s1", ownerA, [ShareGrantee(pubkey: viewer, role: .read)])]
        #expect(SharedSessionACL.turnMode(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants) == .guest)
    }

    @Test("turn mode: the owner is a host")
    func turnModeOwner() {
        let grants = [grant("s1", ownerA, [ShareGrantee(pubkey: viewer, role: .contribute)])]
        #expect(SharedSessionACL.turnMode(identity: ownerA, sessionID: "s1", sessionOwner: ownerA, grants: grants) == .host)
    }

    @Test("turn mode: an unrelated or revoked identity has no mode")
    func turnModeNone() {
        let grants = [grant("s1", ownerA, [ShareGrantee(pubkey: viewer, role: .contribute)])]
        #expect(SharedSessionACL.turnMode(identity: "stranger", sessionID: "s1", sessionOwner: ownerA, grants: grants) == nil)
        #expect(SharedSessionACL.turnMode(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: [grant("s1", ownerA, [], seq: 2)]) == nil)
    }

    @Test("the newest grant wins (by seq) across grants for the same session")
    func newestWins() {
        let grants = [
            grant("s1", ownerA, [ShareGrantee(pubkey: viewer, role: .read)], seq: 1),
            grant("s1", ownerA, [ShareGrantee(pubkey: viewer, role: .contribute)], seq: 3)
        ]
        #expect(SharedSessionACL.role(identity: viewer, sessionID: "s1", sessionOwner: ownerA, grants: grants) == .contribute)
    }

    @Test("owner field round-trips through Session JSON")
    func ownerSessionRoundTrip() throws {
        let s = Session(model: "m", provider: "p", owner: ownerA)
        let back = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
        #expect(back.owner == ownerA)
    }

    @Test("owner field round-trips through TesseraSessionMeta JSON")
    func ownerMetaRoundTrip() throws {
        let meta = TesseraSessionMeta(
            seq: 1, sessionID: "s1", createdAt: Date(), updatedAt: Date(),
            model: "m", provider: "p", messageCount: 0, totalTokens: 0,
            owner: ownerB
        )
        let back = try JSONDecoder().decode(TesseraSessionMeta.self, from: JSONEncoder().encode(meta))
        #expect(back.owner == ownerB)
    }
}
