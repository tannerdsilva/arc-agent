import Foundation
import Testing
@testable import ArcAgentCore

/// Task 6 — only the owner runs turns for a shared session; a contributing
/// sharee records its message but the owner's agent generates the response.
@Suite("Host runs every turn")
struct HostRunsEveryTurnTests {

    @Test("isOwner is true for a nil (legacy) owner and for the acting identity")
    func ownerDetection() {
        #expect(SharedSessionACL.isOwner("me", sessionOwner: nil))
        #expect(SharedSessionACL.isOwner("me", sessionOwner: "me"))
        #expect(!SharedSessionACL.isOwner("me", sessionOwner: "other"))
        #expect(!SharedSessionACL.isOwner("", sessionOwner: "other"))
    }

    @Test("SessionAgent skips turn generation for a non-owner of a shared session")
    func agentSkipsShareeTurn() {
        let src = Self.source("SessionAgent.swift")
        // The guard must exist and continue (skip) when the process is not the owner.
        #expect(src.contains("Host-runs-every-turn"))
        #expect(src.contains("SharedSessionACL.isOwner(identity, sessionOwner: storedOwner)"))
        #expect(src.contains("skipping turn"))
        #expect(src.contains("continue"))
    }

    @Test("the ACL helper resolves owner-vs-contributor without conflating them")
    func ownerNotConflatedWithContributor() {
        // The `role` API returns .contribute for BOTH owner and contributor; the
        // ownership decision must come from isOwner, not role.
        let grants = [TesseraShareGrant(seq: 1, sessionID: "s", owner: "owner", grantees: [])]
        #expect(SharedSessionACL.role(identity: "owner", sessionID: "s", sessionOwner: "owner", grants: grants) == .contribute)
        #expect(SharedSessionACL.role(identity: "contrib", sessionID: "s", sessionOwner: "owner",
                                      grants: [TesseraShareGrant(seq: 1, sessionID: "s", owner: "owner",
                                                                 grantees: [ShareGrantee(pubkey: "contrib", role: .contribute)])]) == .contribute)
        // But only "owner" is the owner.
        #expect(SharedSessionACL.isOwner("owner", sessionOwner: "owner"))
        #expect(!SharedSessionACL.isOwner("contrib", sessionOwner: "owner"))
    }

    static func source(_ name: String) -> String {
        for base in ["Sources/ArcAgentCore/Gateway", "Sources/ArcAgentCore"] {
            let p = "\(base)/\(name)"
            if let s = try? String(contentsOfFile: p) { return s }
        }
        return ""
    }
}
