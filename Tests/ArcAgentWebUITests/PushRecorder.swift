import WebUICore

// The wire recorder the push suites share.
//
// `TurnPresenterWiringTests` reads the markup a turn pushed (its cards);
// `StreamingDomContractTests` reads the batches themselves — ids and ops. One
// type, so both suites observe the same seam instead of each keeping a private
// copy that can drift.
//
// It records BROADCASTS only. It used to carry the door's render bookkeeping as
// well ("a delta batch cost no render", recorded per batch), which died with the
// host-side differ in A10b: a structural batch is now a refresh the server
// performs, so the door has no render to tally. `PushDiffTests` records the
// refresh/broadcast ORDER instead.

/// Records what a producer pushed, in order.
///
/// `push` is the sink to hand a `PushEdge`'s `broadcast` (or a `pusher:`
/// closure).
actor PushRecorder {

    /// One broadcast that crossed the wire.
    struct WireBatch: Sendable, CustomStringConvertible {
        let updates: [FragmentUpdate]

        var ids: [String] { updates.map(\.id) }

        /// A batch is structural when any update re-mounts a node (`op` nil is
        /// `.replace` on the wire); the rest are deltas written into nodes
        /// another producer owns.
        var isStructural: Bool { updates.contains { $0.op == nil || $0.op == .replace } }

        /// The batches whose every update is a delta.
        var isDeltaOnly: Bool { !isStructural }

        var description: String {
            let body = updates.map { update in
                "\(update.id)[\(update.op.map { "\($0)" } ?? "replace")"
                    + (update.html.isEmpty ? "" : " html:\(update.html.count)b")
                    + (update.text.map { " text:\($0.count)b" } ?? "")
                    + "]"
            }.joined(separator: " ")
            return body
        }
    }

    private(set) var log: [WireBatch] = []

    /// every batch, in wire order.
    var batches: [[FragmentUpdate]] { log.map(\.updates) }
    /// every update, flattened.
    var flat: [FragmentUpdate] { log.flatMap(\.updates) }
    /// the markup pushed so far, all batches joined.
    var html: String { flat.map(\.html).joined(separator: "\n") }
    /// the markup in the last batch.
    var lastHTML: String { (batches.last ?? []).map(\.html).joined(separator: "\n") }

    nonisolated var push: @Sendable ([FragmentUpdate]) async -> Void {
        { [weak self] updates in await self?.record(updates) }
    }

    func record(_ updates: [FragmentUpdate]) {
        log.append(WireBatch(updates: updates))
    }
}
