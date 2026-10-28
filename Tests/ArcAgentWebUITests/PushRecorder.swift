import WebUICore

// The wire recorder the push suites share.
//
// `TurnPresenterWiringTests` reads the markup a turn pushed (its cards);
// `StreamingDomContractTests` reads the batches themselves — ids, ops, and the
// door's render bookkeeping at the moment each one crossed. One type, so both
// suites observe the same seam instead of each keeping a private copy that can
// drift.
//
// Render bookkeeping is recorded per batch on purpose: it is the only way to
// state "a delta batch cost no render" as an ORDERED fact (the door renders,
// then broadcasts), rather than inferring it from a total.

/// Records what a producer pushed, in order, alongside what the push door
/// rendered for it.
///
/// `push` is the sink to hand a `PushEdge`'s `broadcast` (or a `pusher:`
/// closure); `noteRender` is the tap to call from the door's `render` closure.
/// A recorder used as a plain pusher simply has no renders.
actor PushRecorder {

    /// One broadcast that crossed the wire, with the door's state at that
    /// moment.
    struct WireBatch: Sendable, CustomStringConvertible {
        let updates: [FragmentUpdate]
        /// how many renders the door had performed when this batch crossed.
        let renders: Int
        /// the markup of the door's last render — nil before the first.
        let render: String?

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
            return "renders=\(renders) \(body)"
        }
    }

    private(set) var log: [WireBatch] = []
    private var rendered: [String] = []

    /// every batch, in wire order.
    var batches: [[FragmentUpdate]] { log.map(\.updates) }
    /// every update, flattened.
    var flat: [FragmentUpdate] { log.flatMap(\.updates) }
    /// the markup pushed so far, all batches joined.
    var html: String { flat.map(\.html).joined(separator: "\n") }
    /// the markup in the last batch.
    var lastHTML: String { (batches.last ?? []).map(\.html).joined(separator: "\n") }
    /// every page the door rendered, in order.
    var renders: [String] { rendered }

    nonisolated var push: @Sendable ([FragmentUpdate]) async -> Void {
        { [weak self] updates in await self?.record(updates) }
    }

    /// the door's render tap — call it from `PushEdge`'s `render` closure.
    func noteRender(_ markup: String) { rendered.append(markup) }

    func record(_ updates: [FragmentUpdate]) {
        log.append(WireBatch(updates: updates, renders: rendered.count, render: rendered.last))
    }
}
