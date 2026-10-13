@testable import ArcAgentCore
import Foundation
import Testing
import tessera_client

// MARK: - Tessera record index (audit fix #1)

/// The O(1) record index extracted from `TesseraConnection`: kind-bucketed
/// snapshots, latest-record-per-d-tag-group lookups, and prefix unindexing.
/// These are the semantics the session store and memory provider now rely on,
/// so they are unit-tested without a live relay.
@Suite("Tessera record index")
struct TesseraRecordIndexTests {

    /// Distinct key-able event id: 32 bytes of a repeating value.
    private func eventID(_ byte: UInt8) -> NOSTR_id {
        let bytes = [UInt8](repeating: byte, count: 32)
        return bytes.withUnsafeBytes {
            NOSTR_id(RAW_staticbuff: $0.load(as: NOSTR_id.RAW_fixed_type.self))
        }
    }

    private func record(_ byte: UInt8, dTag: String?, content: String = "c") -> TesseraRecord {
        TesseraRecord(id: eventID(byte), dTag: dTag, content: content)
    }

    // MARK: groupKey

    @Test("groupKey strips the trailing numeric sequence segment")
    func groupKeyExtraction() {
        #expect(TesseraConnection.groupKey(fromDTag: "arc/meta/s1/12") == "arc/meta/s1")
        #expect(TesseraConnection.groupKey(fromDTag: "arc/m/agent/3") == "arc/m/agent")
        #expect(TesseraConnection.groupKey(fromDTag: "arc/s/demo/0") == "arc/s/demo")
        // No numeric tail, no slash, negative tail → no group.
        #expect(TesseraConnection.groupKey(fromDTag: "arc/meta/s1/abc") == nil)
        #expect(TesseraConnection.groupKey(fromDTag: "flat") == nil)
        #expect(TesseraConnection.groupKey(fromDTag: "arc/meta/s1/-1") == nil)
    }

    // MARK: latest per group

    @Test("latest keeps the highest-seq record per group")
    func latestPerGroup() {
        var index = TesseraRecordIndex()
        index.index(record(1, dTag: "arc/meta/s1/5"), kind: TesseraConnection.metadataKind, seq: 5)
        index.index(record(2, dTag: "arc/meta/s1/9"), kind: TesseraConnection.metadataKind, seq: 9)
        #expect(index.latest(groupKey: "arc/meta/s1")?.dTag == "arc/meta/s1/9")
        #expect(index.latest(groupKey: "arc/meta/s2") == nil, "unrelated group untouched")
        // A lower-seq record never displaces the latest.
        index.index(record(3, dTag: "arc/meta/s1/2"), kind: TesseraConnection.metadataKind, seq: 2)
        #expect(index.latest(groupKey: "arc/meta/s1")?.dTag == "arc/meta/s1/9")
    }

    @Test("groups are isolated by kind and prefix")
    func groupIsolation() {
        var index = TesseraRecordIndex()
        index.index(record(1, dTag: "arc/meta/s1/1"), kind: TesseraConnection.metadataKind, seq: 1)
        index.index(record(2, dTag: "arc/m/agent/1"), kind: TesseraConnection.memoryKind, seq: 1)
        index.index(record(3, dTag: "arc/s/s1/1"), kind: TesseraConnection.messageKind, seq: 1)
        let groups = index.latestGroups(prefix: "arc/meta/")
        #expect(groups.count == 1)
        #expect(groups["arc/meta/s1"]?.content == "c")
        #expect(index.latest(groupKey: "arc/m/agent")?.dTag == "arc/m/agent/1")
        #expect(index.snapshot(kind: TesseraConnection.messageKind).count == 1)
        #expect(index.snapshot(kind: TesseraConnection.metadataKind).count == 1)
    }

    // MARK: unindex

    @Test("unindex removes a prefix across a kind and keeps the rest")
    func unindexPrefix() {
        var index = TesseraRecordIndex()
        index.index(record(1, dTag: "arc/meta/s1/1"), kind: TesseraConnection.metadataKind, seq: 1)
        index.index(record(2, dTag: "arc/meta/s2/1"), kind: TesseraConnection.metadataKind, seq: 1)
        index.index(record(3, dTag: "arc/m/agent/1"), kind: TesseraConnection.memoryKind, seq: 1)
        index.unindex(dTagPrefix: "arc/meta/s1/", kind: TesseraConnection.metadataKind)
        #expect(index.snapshot(kind: TesseraConnection.metadataKind).count == 1)
        #expect(index.latest(groupKey: "arc/meta/s1") == nil)
        #expect(index.latest(groupKey: "arc/meta/s2") != nil)
        #expect(index.snapshot(kind: TesseraConnection.memoryKind).count == 1, "other kinds untouched")
        #expect(index.count == 2, "removed id dropped from the id set")
    }

    @Test("unindex of the last record under an id clears the id when no other kind holds it")
    func unindexClearsIDs() {
        var index = TesseraRecordIndex()
        index.index(record(1, dTag: "arc/s/s1/1"), kind: TesseraConnection.messageKind, seq: 1)
        index.index(record(1, dTag: "arc/s/s1/1"), kind: TesseraConnection.messageKind, seq: 2) // same id re-index
        #expect(index.count == 1)
        index.unindex(dTagPrefix: "arc/s/s1/", kind: TesseraConnection.messageKind)
        #expect(index.count == 0)
    }

    @Test("records without an id are ignored; snapshots reflect only the requested kind")
    func nilIDsAndScoping() {
        var index = TesseraRecordIndex()
        index.index(TesseraRecord(id: nil, dTag: "arc/meta/s1/1", content: "x"),
                    kind: TesseraConnection.metadataKind, seq: 1)
        #expect(index.count == 0)
        #expect(index.latest(groupKey: "arc/meta/s1") == nil)
    }
}
