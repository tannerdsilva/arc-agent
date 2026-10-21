import Foundation
import Testing
@testable import ArcAgentCore

/// Phase 2 — sharee→owner wake bridge. The pure `shareeContributions`
/// filter attributes kind-3001 user messages to a sharee (any signer other
/// than the session owner), which is what a host uses to wake its turn
/// engine when a granted guest contributes.
@Suite("Sharee wake bridge", .serialized)
struct ShareeWakeTests {

    private func msg(_ seq: Int, session: String, role: Message.Role, text: String?, author: String?) throws -> TesseraRecord {
        let stored = TesseraStoredMessage(seq: seq, sessionID: session, message: Message(role: role, content: text))
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8)!
        return TesseraRecord(id: nil, dTag: "arc/s/\(session)/\(seq)", content: json, author: author)
    }

    @Test("a guest's user message is a sharee contribution")
    func guestContribution() throws {
        let recs = try [msg(5, session: "s1", role: .user, text: "guest says hi", author: "guestKey")]
        let out = TesseraConnection.shareeContributions(recs, owner: "ownerKey", sessionID: "s1")
        #expect(out.count == 1)
        #expect(out[0].text == "guest says hi")
        #expect(out[0].author == "guestKey")
        #expect(out[0].seq == 5)
    }

    @Test("the owner's own messages are never wake signals")
    func ownMessageExcluded() throws {
        let recs = try [msg(3, session: "s1", role: .user, text: "my msg", author: "ownerKey")]
        #expect(TesseraConnection.shareeContributions(recs, owner: "ownerKey", sessionID: "s1").isEmpty)
    }

    @Test("assistant messages are not contributions even from a sharee")
    func assistantExcluded() throws {
        let recs = try [msg(7, session: "s1", role: .assistant, text: "owner's answer", author: "guestKey")]
        #expect(TesseraConnection.shareeContributions(recs, owner: "ownerKey", sessionID: "s1").isEmpty)
    }

    @Test("records from other sessions are ignored")
    func otherSessionExcluded() throws {
        let recs = try [msg(9, session: "s2", role: .user, text: "other", author: "guestKey")]
        #expect(TesseraConnection.shareeContributions(recs, owner: "ownerKey", sessionID: "s1").isEmpty)
    }

    @Test("un-indexed records (nil author) are ignored")
    func nilAuthorExcluded() throws {
        let recs = try [msg(11, session: "s1", role: .user, text: "pending", author: nil)]
        #expect(TesseraConnection.shareeContributions(recs, owner: "ownerKey", sessionID: "s1").isEmpty)
    }

    @Test("contributions are returned in ascending sequence order")
    func sortedBySeq() throws {
        let recs = try [
            msg(20, session: "s1", role: .user, text: "second", author: "guestKey"),
            msg(10, session: "s1", role: .user, text: "first", author: "guestKey"),
        ]
        let out = TesseraConnection.shareeContributions(recs, owner: "ownerKey", sessionID: "s1")
        #expect(out.map { $0.seq } == [10, 20])
    }
}
