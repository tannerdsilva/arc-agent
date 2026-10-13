import Foundation
import tessera_client

/// Pure, actor-free index over cached Tessera records (audit fix #1).
///
/// Taken out of `TesseraConnection` so the index semantics are unit-testable
/// without a live relay. The actor owns one of these and updates it
/// incrementally on every local publish (O(1)) and on rare external
/// reconciliations (O(model)):
///
/// - Records are bucketed by event kind, so `snapshot(kind:)` costs
///   O(records of that kind) instead of a walk over the entire model
///   (which holds every kind and every session — the old O(n) per
///   operation made long sessions quadratic).
/// - The newest record per d-tag *group* (a d-tag minus its trailing
///   `/<seq>`, e.g. `arc/meta/<session>` or `arc/m/<key>`) is kept, so
///   "latest meta for session X" / "latest memory for key Y" are O(1)
///   lookups.
internal struct TesseraRecordIndex {

    /// Kind → record id → record.
    private(set) var records: [UInt32: [NOSTR_id: TesseraRecord]] = [:]

    /// Every record id currently indexed (local writes + reconciled external
    /// arrivals). Its size is what the connection's convergence check
    /// compares against the model's size.
    private(set) var ids: Set<NOSTR_id> = []

    /// Latest record per d-tag group.
    private(set) var groups: [String: TesseraRecord] = [:]

    /// Insert (or replace) a record. O(1). For a group, only the record with
    /// the greater sequence number is kept.
    mutating func index(_ record: TesseraRecord, kind: UInt32, seq: Int) {
        guard let id = record.id else { return }
        records[kind, default: [:]][id] = record
        ids.insert(id)
        guard let dTag = record.dTag, let group = TesseraConnection.groupKey(fromDTag: dTag) else {
            return
        }
        if let current = groups[group] {
            let currentSeq = current.dTag.flatMap(TesseraConnection.sequenceNumber(fromTagKey:)) ?? -1
            if seq > currentSeq {
                groups[group] = record
            }
        } else {
            groups[group] = record
        }
    }

    /// Remove every record whose d-tag falls under a prefix (after a local
    /// `deleteAll` was applied).
    ///
    /// Callers pass prefixes with a trailing slash (e.g. `arc/s/<id>/`), which
    /// matches record d-tags (`arc/s/<id>/<seq>`) but not group keys
    /// (`arc/s/<id>`), so the group under a trailing-slash prefix is removed
    /// too.
    mutating func unindex(dTagPrefix prefix: String, kind: UInt32) {
        let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let removed: [NOSTR_id] = (records[kind] ?? [:])
            .filter { $0.value.dTag?.hasPrefix(prefix) == true }
            .map(\.key)
        records[kind] = (records[kind] ?? [:])
            .filter { $0.value.dTag?.hasPrefix(prefix) != true }
        groups = groups.filter {
            !($0.key.hasPrefix(prefix) || $0.key == trimmed)
        }
        for id in removed {
            if !records.values.contains(where: { $0[id] != nil }) {
                ids.remove(id)
            }
        }
    }

    /// All records of one kind (unbounded order; callers sort by seq).
    func snapshot(kind: UInt32) -> [TesseraRecord] {
        Array((records[kind] ?? [:]).values)
    }

    /// The record with the greatest sequence number in a group, if any.
    func latest(groupKey: String) -> TesseraRecord? {
        groups[groupKey]
    }

    /// Every group under a prefix, one record each.
    func latestGroups(prefix: String) -> [String: TesseraRecord] {
        groups.filter { $0.key.hasPrefix(prefix) }
    }

    /// Number of distinct records indexed.
    var count: Int { ids.count }
}
