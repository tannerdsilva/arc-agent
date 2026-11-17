import Foundation

extension KanbanAgent {

    /// Pure traversal helpers (spec 04 §2–§3). No I/O, no time-of-check
    /// hazards — everything takes explicit state and a `now` where time
    /// matters, so the engine's decisions are unit-testable without LLMs.
    public enum KanbanTraversal {

        /// The root's tree: the first card plus every descendant, in
        /// generation order (array order = creation order per level).
        public static func tree(of root: Root, in cards: [Card]) -> [Card] {
            let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            guard let first = byID[root.firstCardID] else { return [] }
            var tree: [Card] = []
            func walk(_ card: Card) {
                tree.append(card)
                for child in cards where child.parentID == card.id {
                    walk(child)
                }
            }
            walk(first)
            return tree
        }

        /// Whether the card's result is *fresh*: produced after the card's
        /// last move. A fresh result in a work column awaits its transition;
        /// a stale one means the card must run again in its new column.
        private static func hasFreshResult(_ card: Card) -> Bool {
            guard card.result != nil else { return false }
            let lastMove = card.transitionProvenance.last?.at ?? .distantPast
            return lastMove <= (card.result?.producedAt ?? .distantPast)
        }

        /// Post-order, deepest-first: the next card to execute is the deepest
        /// runnable descendant not yet done — children before parents, since
        /// a parent consumes its children's outputs (design doc §6).
        ///
        /// A card is runnable when:
        /// - it sits in an `agentWork` column,
        /// - its result is absent or stale (already transitioned since the
        ///   last run — each work-column visit is one turn),
        /// - all of its children are done,
        /// - it is not in triage cooldown (`triageRetryAt` in the future).
        public static func nextRunnableCard(
            in cards: [Card], root: Root, graph: BoardGraph, now: Date = Date()
        ) -> Card? {
            let tree = Self.tree(of: root, in: cards)
            guard !tree.isEmpty else { return nil }

            func children(of card: Card) -> [Card] {
                tree.filter { $0.parentID == card.id }
            }
            func isDone(_ card: Card) -> Bool {
                graph.column(id: card.columnID)?.kind == .terminal
            }
            func isRunnable(_ card: Card) -> Bool {
                guard graph.column(id: card.columnID)?.kind == .agentWork else { return false }
                guard !hasFreshResult(card) else { return false }
                guard children(of: card).allSatisfy({ isDone($0) }) else { return false }
                if let retryAt = card.triageRetryAt, retryAt > now { return false }
                return true
            }

            // Depth-first from the first card; return the first runnable in
            // the deepest-first walk (children strictly before parents).
            func walk(_ card: Card) -> Card? {
                for child in children(of: card) {
                    if let hit = walk(child) { return hit }
                }
                return isRunnable(card) ? card : nil
            }
            return walk(tree[0])
        }

        /// Cards that finished executing but have not transitioned yet —
        /// the engine's pending-transition set. A result is pending when it
        /// is fresh (no move since it was produced).
        public static func pendingTransitions(in cards: [Card], root: Root, graph: BoardGraph) -> [Card] {
            tree(of: root, in: cards).filter { card in
                hasFreshResult(card)
                    && graph.column(id: card.columnID)?.kind == .agentWork
                    && card.readiness != .done
                    // Drain rule: children resolve strictly first.
                    && cards.filter { $0.parentID == card.id }
                        .allSatisfy { $0.readiness == .done }
            }
        }

        /// The next root to run: first `running` root in the document's
        /// creation order. Yellow roots are absent from the queue by not
        /// being `.running` (spec 04 §3); `resume` returns them to the head
        /// by moving them to index 0 and setting `.running`.
        public static func nextRoot(in document: BoardDocument) -> Root? {
            document.roots.first { $0.state == .running }
        }

        /// Budgets remaining for a root (spec 05 §3): minted children are
        /// counted from the tree, allowances come from board settings.
        public static func mintedChildren(of root: Root, in cards: [Card]) -> Int {
            tree(of: root, in: cards).filter { $0.generation > 0 }.count
        }
    }
}
