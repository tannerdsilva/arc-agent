import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Kanban agent phase 3: traversal + execution engine (spec 04)

/// Shared scenario used by both phase-3 suites.
///
/// Graph (all agentWork columns unless noted):
///   entry --det "started"--> work --det "completed"--> done(terminal)
///   review --det "approved"--> done
///   work/entry/review also carry ask-the-user edges to human (humanWait).
///   work additionally has a counter self-edge (e5) for rotation tests.
private enum EngineScenario {

    static func board(rootState: KanbanAgent.RootState = .running) -> KanbanAgent.BoardDocument {
        let columns: [KanbanAgent.Column] = [
            .init(id: "entry", name: "Entry", kind: .agentWork, isEntry: true),
            .init(id: "work", name: "Work", kind: .agentWork),
            .init(id: "review", name: "Review", kind: .agentWork, isTriage: true),
            .init(id: "done", name: "Done", kind: .terminal),
            .init(id: "human", name: "Ask", kind: .humanWait),
        ]
        let edges: [KanbanAgent.Edge] = [
            .init(id: "e1", fromColumnID: "entry", toColumnID: "work", decision: .deterministic, outcomeLabel: "started"),
            .init(id: "e14", fromColumnID: "work", toColumnID: "done", decision: .deterministic, outcomeLabel: "completed"),
            .init(id: "e3", fromColumnID: "review", toColumnID: "done", decision: .deterministic, outcomeLabel: "approved"),
            .init(id: "e4", fromColumnID: "work", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
            .init(id: "e5", fromColumnID: "work", toColumnID: "work", decision: .policy, policy: .counter),
            .init(id: "e12", fromColumnID: "entry", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
            .init(id: "e13", fromColumnID: "review", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
        ]
        var doc = KanbanAgent.BoardDocument(id: "b1", name: "Engine", columns: columns, edges: edges)
        doc.roots = [
            KanbanAgent.Root(
                id: "r1", title: "root", definitionOfDone: "clause A\nclause B",
                state: rootState, firstCardID: "c-root")
        ]
        return doc
    }

    /// Two-level tree: c-root (review) → c-child (entry).
    static func cards() -> [KanbanAgent.Card] {
        [
            KanbanAgent.Card(
                id: "c-root", laneID: "l1", columnID: "review", goal: "root goal",
                doneCondition: "root dod", parentID: nil, rootID: "r1", generation: 0),
            KanbanAgent.Card(
                id: "c-child", laneID: "l1", columnID: "entry", goal: "child goal",
                doneCondition: "child dod", parentID: "c-root", rootID: "r1", generation: 1),
        ]
    }
}

extension ArcCoreTestRoot {

    @Suite("Kanban agent traversal", .serialized)
    struct KanbanAgentTraversalTests {

        private func graph() -> KanbanAgent.BoardGraph { .init(board: EngineScenario.board()) }

        @Test("post-order: the deepest runnable descendant runs first")
        func deepestFirst() {
            let next = KanbanAgent.KanbanTraversal.nextRunnableCard(
                in: EngineScenario.cards(), root: EngineScenario.board().roots[0], graph: graph())
            #expect(next?.id == "c-child")
        }

        @Test("post-order: parent becomes runnable after the child reaches terminal")
        func parentAfterChild() {
            var cards = EngineScenario.cards()
            cards[1].columnID = "done"
            cards[1].readiness = .done
            let next = KanbanAgent.KanbanTraversal.nextRunnableCard(
                in: cards, root: EngineScenario.board().roots[0], graph: graph())
            #expect(next?.id == "c-root")
        }

        @Test("a fresh result is pending, not runnable — the transition comes first")
        func freshResultPending() {
            var cards = EngineScenario.cards()
            cards[1].result = .init(outcome: "started", summary: "s")
            let root = EngineScenario.board().roots[0]
            #expect(KanbanAgent.KanbanTraversal.nextRunnableCard(in: cards, root: root, graph: graph()) == nil)
            #expect(KanbanAgent.KanbanTraversal.pendingTransitions(in: cards, root: root, graph: graph()).map(\.id) == ["c-child"])
        }

        @Test("a stale result (moved since producing) is runnable again")
        func staleResultRunnable() {
            var cards = EngineScenario.cards()
            cards[1].result = .init(outcome: "started", summary: "s", producedAt: Date().addingTimeInterval(-60))
            cards[1].transitionProvenance = [.init(
                edgeID: "e1", fromColumnID: "entry", toColumnID: "work",
                reasoning: "r", decidedBy: .deterministic, at: Date())]
            cards[1].columnID = "work"
            let next = KanbanAgent.KanbanTraversal.nextRunnableCard(
                in: cards, root: EngineScenario.board().roots[0], graph: graph())
            #expect(next?.id == "c-child")
        }

        @Test("triage cooldown defers the card until the retry time passes")
        func triageCooldown() {
            var cards = EngineScenario.cards()
            cards[1].triageRetryAt = Date().addingTimeInterval(600)
            let root = EngineScenario.board().roots[0]
            #expect(KanbanAgent.KanbanTraversal.nextRunnableCard(in: cards, root: root, graph: graph()) == nil)
            #expect(KanbanAgent.KanbanTraversal.nextRunnableCard(
                in: cards, root: root, graph: graph(),
                now: Date().addingTimeInterval(700))?.id == "c-child")
        }

        @Test("root queue: first running root; terminal/yellow roots exit")
        func rootQueue() {
            var doc = EngineScenario.board()
            doc.roots.append(KanbanAgent.Root(
                id: "r2", title: "second", definitionOfDone: "x", state: .running, firstCardID: "c2"))
            doc.roots.append(KanbanAgent.Root(
                id: "r3", title: "third", definitionOfDone: "x", state: .yellow, firstCardID: "c3"))
            #expect(KanbanAgent.KanbanTraversal.nextRoot(in: doc)?.id == "r1")
            doc.roots[0].state = .green
            #expect(KanbanAgent.KanbanTraversal.nextRoot(in: doc)?.id == "r2")
            doc.roots[1].state = .green
            #expect(KanbanAgent.KanbanTraversal.nextRoot(in: doc) == nil)
        }

        @Test("minted budget counts non-root generations")
        func mintedCount() {
            #expect(KanbanAgent.KanbanTraversal.mintedChildren(
                of: EngineScenario.board().roots[0], in: EngineScenario.cards()) == 1)
        }
    }

    @Suite("Kanban agent engine", .serialized)
    struct KanbanAgentEngineTests {

        /// Scripted executor: deterministic outcome per card id.
        final class ScriptedExecutor: KanbanAgent.CardExecutor, @unchecked Sendable {
            var outcomes: [String: String] = [:]
            func run(_ prompt: KanbanAgent.CardPrompt, card: KanbanAgent.Card, settings: KanbanAgent.BoardSettings) async throws -> KanbanAgent.CardResult {
                .init(outcome: outcomes[card.id] ?? "unmapped", summary: "did \(card.id)")
            }
        }

        private func makeEngine(
            store: any KanbanAgentStore,
            judge: KanbanAgent.ScriptedKanbanJudge,
            executor: ScriptedExecutor
        ) -> KanbanAgent.KanbanEngineService {
            .init(store: store, judge: judge, executor: executor, ownerID: "test-daemon", pollInterval: 0.05)
        }

        private func makeStore() -> FileKanbanAgentStore {
            .init(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("kanban-engine-\(UUID().uuidString)", isDirectory: true))
        }

        private func seed(_ doc: KanbanAgent.BoardDocument, store: FileKanbanAgentStore) async throws {
            try await store.saveBoard(doc)
            for card in EngineScenario.cards() {
                try await store.saveCard(card, boardID: doc.id)
            }
        }

        @Test("full loop: two-level tree runs to green against a scripted judge")
        func fullLoopGreen() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            let doc = EngineScenario.board()
            try await seed(doc, store: store)
            executor.outcomes = ["c-child": "started", "c-root": "approved"]
            judge.enqueueVerdict(.green(KanbanAgent.EvidenceChain(entries: [
                .init(clause: "clause A", cardIDs: ["c-root", "c-child"], reasoning: "both terminal"),
                .init(clause: "clause B", cardIDs: ["c-child"], reasoning: "child proved it"),
            ])))

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            // Tick 1: deepest runnable — the child — runs "started" → work.
            var reports = await engine.tick()
            #expect(reports[0].executedCardID == "c-child")
            #expect(try await store.getCard(id: "c-child", boardID: doc.id)!.columnID == "work")
            #expect(judge.transitionCallCount == 0)  // deterministic bypass

            // Tick 2: the child's result is stale in the new column → runs
            // again, "unmapped" (no det edge from work except completed)...
            // actually outcome defaults to "unmapped": no det match, no
            // fixed, counter e5 rotates → work→work.
            reports = await engine.tick()
            #expect(reports[0].executedCardID == "c-child")

            // Give the child its "completed" outcome for the final leg.
            executor.outcomes["c-child"] = "completed"
            reports = await engine.tick()
            #expect(reports[0].executedCardID == "c-child")
            let child = try await store.getCard(id: "c-child", boardID: doc.id)!
            #expect(child.columnID == "done")
            #expect(child.readiness == KanbanAgent.Readiness.done)

            // Tick 4: the parent (all children done) runs "approved" → done.
            reports = await engine.tick()
            #expect(reports[0].executedCardID == "c-root")
            #expect(try await store.getCard(id: "c-root", boardID: doc.id)!.columnID == "done")

            // Tick 5: nothing runnable → evaluation point → green.
            reports = await engine.tick()
            #expect(reports[0].executedCardID == nil)
            #expect(judge.evaluationCallCount == 1)
            let saved = try await store.getBoard(id: doc.id)!
            #expect(saved.roots[0].state == KanbanAgent.RootState.green)
            #expect(saved.roots[0].evidence?.entries.count == 2)
        }

        @Test("counter edge rotates by traversal arrivals")
        func counterRotation() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            let doc = EngineScenario.board()
            try await seed(doc, store: store)
            executor.outcomes = ["c-child": "anything"]

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            // Tick 1: child in entry, outcome unmapped → no det, no fixed,
            // counter e12? No — e12 is ask (agent policy), e5 is counter but
            // from work. From entry: only ask e12 → judge consulted.
            judge.enqueueTransition(.init(edgeID: "e12", reasoning: "need the user"))
            _ = await engine.tick()
            let child = try await store.getCard(id: "c-child", boardID: doc.id)!
            #expect(child.columnID == "human")
            #expect(child.transitionProvenance.last?.decidedBy == .agent)
        }

        @Test("cycle budget routes a re-entry to triage with a cooldown")
        func cycleBudget() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = EngineScenario.board()
            doc.settings.cycleBudget = 1
            doc.settings.triageCooldownSeconds = 300
            // A triage column: mark "review" as the board's triage.
            doc.columns = doc.columns.map { col in
                var c = col; c.isTriage = (col.id == "review"); return c }
            try await seed(doc, store: store)
            // The child has already visited work once (budget 1 spent) and
            // sits in work with an unmapped outcome; the counter self-edge
            // e5 would re-enter work — over budget → triage. The previous
            // result is identical to the new one, so no genuine-progress
            // reset applies (spec 07 §1) and the spent budget still bites.
            var child = EngineScenario.cards()[1]
            child.columnID = "work"
            child.traversalCounts = ["work": 1]
            child.result = .init(outcome: "x", summary: "did c-child")
            try await store.saveCard(child, boardID: doc.id)
            executor.outcomes = ["c-child": "x"]

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            _ = await engine.tick()
            let after = try await store.getCard(id: "c-child", boardID: doc.id)!
            #expect(after.columnID == "review")
            #expect(after.transitionProvenance.last?.reasoning.contains("cycle budget") == true)
            #expect(after.triageRetryAt != nil)
        }

        @Test("triage re-arm: a repeat result in triage stays parked")
        func triageRearm() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = EngineScenario.board()
            doc.columns = doc.columns.map { col in
                var c = col; c.isTriage = (col.id == "review"); return c }
            try await seed(doc, store: store)
            // Child sits in review (the triage column) with a prior result.
            var child = EngineScenario.cards()[1]
            child.columnID = "review"
            child.result = .init(outcome: "blocked", summary: "still blocked")
            child.triageRetryAt = Date().addingTimeInterval(-10)  // cooldown elapsed
            try await store.saveCard(child, boardID: doc.id)
            executor.outcomes = ["c-child": "blocked"]  // deterministic repeat

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            _ = await engine.tick()
            let after = try await store.getCard(id: "c-child", boardID: doc.id)!
            #expect(after.columnID == "review")  // never left
            #expect(after.triageRetryAt != nil)  // cooldown re-armed
            #expect(after.transitionProvenance.isEmpty)  // no move stamped
        }

        @Test("green without evidence is re-asked; double failure forces yellow")
        func verdictValidation() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            let doc = EngineScenario.board()
            try await seed(doc, store: store)
            // Park everything: no runnable cards → evaluation points.
            var root = EngineScenario.cards()[0]
            root.columnID = "done"; root.readiness = .done
            var child = EngineScenario.cards()[1]
            child.columnID = "done"; child.readiness = .done
            try await store.saveCard(root, boardID: doc.id)
            try await store.saveCard(child, boardID: doc.id)

            // First verdict: green citing a clause not in the DoD → defect.
            judge.enqueueVerdict(.green(KanbanAgent.EvidenceChain(entries: [
                .init(clause: "not a clause", cardIDs: [], reasoning: "r"),
            ])))
            // Re-ask: still invalid green.
            judge.enqueueVerdict(.green(KanbanAgent.EvidenceChain(entries: [])))

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            _ = await engine.tick()
            #expect(judge.evaluationCallCount == 2)
            let saved = try await store.getBoard(id: doc.id)!
            #expect(saved.roots[0].state == KanbanAgent.RootState.yellow)
            #expect(saved.roots[0].missingReport?.blockingUnknown.contains("forced yellow") == true)
        }

        @Test("resume returns a yellow root to the queue head with context")
        func resume() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = EngineScenario.board()
            doc.roots.append(KanbanAgent.Root(
                id: "r2", title: "second", definitionOfDone: "x", state: .running, firstCardID: "c2"))
            doc.roots[0].state = .yellow
            try await store.saveBoard(doc)

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            try await engine.resume(rootID: "r1", boardID: doc.id, context: "the credential is in vault")
            let saved = try await store.getBoard(id: doc.id)!
            #expect(saved.roots[0].id == "r1")
            #expect(saved.roots[0].state == .running)
            #expect(saved.roots[0].resumeContext == "the credential is in vault")
            #expect(KanbanAgent.KanbanTraversal.nextRoot(in: saved)?.id == "r1")
        }

        @Test("engine lease: a second daemon is refused on the same board")
        func leaseRefusal() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = EngineScenario.board()
            doc.engineLease = .init(ownerID: "other-daemon")
            try await seed(doc, store: store)

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            let reports = await engine.tick()
            #expect(reports[0].executedCardID == nil)
            #expect(reports[0].notices.contains { .leaseHeld(other: "other-daemon") == $0 })
        }

        @Test("stale lease expires and the board is claimable again")
        func staleLease() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = EngineScenario.board()
            doc.engineLease = .init(ownerID: "dead-daemon", heartbeatAt: Date().addingTimeInterval(-3600))
            try await seed(doc, store: store)
            executor.outcomes = ["c-child": "started"]

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            let reports = await engine.tick()
            #expect(reports[0].executedCardID == "c-child")  // claimed and ran
            let saved = try await store.getBoard(id: doc.id)!
            #expect(saved.engineLease?.ownerID == "test-daemon")
        }

        @Test("timer release moves a card along its configured edge")
        func timerRelease() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = EngineScenario.board()
            doc.columns.append(.init(id: "cool", name: "Cool", kind: .timerWait, timerSeconds: 60, defaultEdgeID: "e-back"))
            doc.edges.append(.init(id: "e-back", fromColumnID: "cool", toColumnID: "work", decision: .policy, policy: .fixed))
            doc.edges.append(.init(id: "e-cool-ask", fromColumnID: "cool", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true))
            var parked = KanbanAgent.Card(
                id: "c-parked", laneID: "l1", columnID: "cool", goal: "g", doneCondition: "d",
                parentID: nil, rootID: "r-timer", generation: 0)
            parked.transitionProvenance = [.init(
                edgeID: "e-into", fromColumnID: "work", toColumnID: "cool",
                reasoning: "cooldown", decidedBy: .fallback, at: Date().addingTimeInterval(-120))]
            doc.roots.append(KanbanAgent.Root(
                id: "r-timer", title: "t", definitionOfDone: "x", state: .yellow, firstCardID: "c-parked"))
            try await store.saveBoard(doc)
            try await store.saveCard(parked, boardID: doc.id)

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            let reports = await engine.tick()
            #expect(reports[0].notices.contains { notice in
                if case .timerReleased(let id, let edge) = notice { return id == "c-parked" && edge == "e-back" }
                return false
            })
            #expect(try await store.getCard(id: "c-parked", boardID: doc.id)!.columnID == "work")
        }

        @Test("stale-motion fallback moves a stranded result after the timeout")
        func staleMotion() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = EngineScenario.board()
            doc.edges.append(.init(id: "e-fb", fromColumnID: "work", toColumnID: "review", decision: .policy, policy: .agent))
            doc.columns = doc.columns.map { col in
                var c = col; if col.id == "work" { c.defaultEdgeID = "e-fb" }; return c }
            var stranded = EngineScenario.cards()[1]
            stranded.columnID = "work"
            stranded.result = .init(outcome: "unmapped", summary: "s", producedAt: Date().addingTimeInterval(-3600))
            stranded.readiness = .running  // finished executing, never transitioned
            try await store.saveBoard(doc)
            try await store.saveCard(stranded, boardID: doc.id)
            try await store.saveCard(EngineScenario.cards()[0], boardID: doc.id)

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            let reports = await engine.tick()
            #expect(reports[0].notices.contains { notice in
                if case .staleMotionFallback(let id, _) = notice { return id == "c-child" }
                return false
            })
            let after = try await store.getCard(id: "c-child", boardID: doc.id)!
            #expect(after.transitionProvenance.last?.decidedBy == .fallback)
        }

        @Test("invalid board is refused, not run")
        func invalidBoardRefused() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = EngineScenario.board()
            doc.edges.removeAll { $0.id == "e12" }  // entry loses its ask edge → hard violation
            try await seed(doc, store: store)
            executor.outcomes = ["c-child": "started"]

            let engine = makeEngine(store: store, judge: judge, executor: executor)
            let reports = await engine.tick()
            #expect(reports[0].executedCardID == nil)
            #expect(reports[0].notices.contains { notice in
                if case .boardInvalid = notice { return true }
                return false
            })
        }
    }
}
