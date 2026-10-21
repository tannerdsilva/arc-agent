import Foundation
import Testing
@testable import ArcAgentCore

/// Phase 3 — owner→guest streaming delta (kind 3008). Verifies the
/// `TesseraStreamDelta` payload round-trips through Codable and that the
/// connection's d-tag scheme is stable.
@Suite("Streaming delta", .serialized)
struct StreamDeltaTests {

    @Test("delta round-trips through Codable preserving every field")
    func roundTrip() throws {
        let delta = TesseraStreamDelta(
            seq: 42, sessionID: "s1", messageSeq: 7,
            text: "hel", final: false, owner: "hostKey"
        )
        let data = try JSONEncoder().encode(delta)
        let decoded = try JSONDecoder().decode(TesseraStreamDelta.self, from: data)
        #expect(decoded == delta)
        #expect(decoded.seq == 42)
        #expect(decoded.sessionID == "s1")
        #expect(decoded.messageSeq == 7)
        #expect(decoded.text == "hel")
        #expect(!decoded.final)
        #expect(decoded.owner == "hostKey")
    }

    @Test("the final marker survives the round-trip")
    func finalMarker() throws {
        let delta = TesseraStreamDelta(
            seq: 43, sessionID: "s1", messageSeq: 7,
            text: "complete", final: true, owner: "hostKey"
        )
        let decoded = try JSONDecoder().decode(
            TesseraStreamDelta.self,
            from: JSONEncoder().encode(delta)
        )
        #expect(decoded.final)
    }

    @Test("stream d-tag prefix is stable for matching")
    func dTagScheme() {
        #expect(TesseraConnection.streamKind == 3_008)
        let dTag = "arc/stream/s1/42"
        #expect(dTag.hasPrefix("arc/stream/s1/"))
        #expect(TesseraConnection.sequenceNumber(fromTagKey: dTag) == 42)
    }
}
