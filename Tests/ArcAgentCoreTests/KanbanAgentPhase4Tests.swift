import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Kanban agent phase 4: agent verbs (spec 05)

extension ArcCoreTestRoot {

    @Suite("Kanban agent verbs", .serialized)
    struct KanbanAgentVerbTests {

        final class ScriptedExecutor: KanbanAgent.CardExecutor, @unchecked Sendable {
            var outcomes: [String: String] = [:]
            func run(_ prompt: KanbanAgent.CardPrompt, card: KanbanAgent.Card, settings: KanbanAgent.BoardSettings) async throws -> KanbanAgent.CardResult {
                .init(outcome: outcomes[card.id] ?? "unmapped", summary: "did \(card.id)")
            }
        }

        /// The scenario board from phase 3, reused: entry --started--> work
        /// --completed--> done; review (triage) --approved--> done; ask edges.
        private func board() -> KanbanAgent.BoardDocument {
            var doc = KanbanAgent.BoardDocument(id: "b1", name: "Verbs", columns: [
                .init(id: "entry", name: "Entry", kind: .agentWork, isEntry: true),
                .init(id: "work", name: "Work", kind: .agentWork),
                .init(id: "review", name: "Review", kind: .agentWork, isTriage: true),
                .init(id: "done", name: "Done", kind: .terminal),
                .init(id: "human", name: "Ask", kind: .humanWait),
            ], edges: [
                .init(id: "e1", fromColumnID: "entry", toColumnID: "work", decision: .deterministic, outcomeLabel: "started"),
                .init(id: "e14", fromColumnID: "work", toColumnID: "done", decision: .deterministic, outcomeLabel: "completed"),
                .init(id: "e3", fromColumnID: "review", toColumnID: "done", decision: .deterministic, outcomeLabel: "approved"),
                .init(id: "e4", fromColumnID: "work", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
                .init(id: "e5", fromColumnID: "work", toColumnID: "work", decision: .policy, policy: .counter),
                .init(id: "e12", fromColumnID: "entry", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
                .init(id: "e13", fromColumnID: "review", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
            ])
            doc.roots = [.init(id: "r1", title: "root", definitionOfDone: "clause A\nclause B", state: .running, firstCardID: "c-root")]
            return doc
        }

        private func makeStore() -> FileKanbanAgentStore {
            .init(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("kanban-verbs-\(UUID().uuidString)", isDirectory: true))
        }

        private func seed(_ doc: KanbanAgent.BoardDocument, _ store: FileKanbanAgentStore) async throws {
            try await store.saveBoard(doc)
            try await store.saveCard(KanbanAgent.Card(
                id: "c-root", laneID: "l1", columnID: "review", goal: "root goal",
                doneCondition: "root dod", parentID: nil, rootID: "r1"), boardID: doc.id)
            try await store.saveCard(KanbanAgent.Card(
                id: "c-child", laneID: "l1", columnID: "entry", goal: "child goal",
                doneCondition: "child dod", parentID: "c-root", rootID: "r1", generation: 1),
                boardID: doc.id)
        }

        @Test("verb 2: a parent with a fresh result and no children mints under budget")
        func minting() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            let doc = board()
            try await seed(doc, store)
            executor.outcomes = ["c-child": "started"]
            judge.enqueueGeneration([
                .init(goal: "fetch the token", input: .init(mode: .summary, sourceCardID: "c-child", payload: "s"),
                      doneCondition: "token in hand", targetColumnID: "work", whyNext: "needs the credential first"),
                .init(goal: "validate the token", input: .init(mode: .reference, sourceCardID: "c-child", payload: "art-1"),
                      doneCondition: "validation passes", targetColumnID: "work", whyNext: "independent check"),
            ])

            let engine = KanbanAgent.KanbanEngineService(
                store: store, judge: judge, executor: executor, ownerID: "test", pollInterval: 0.05)
            let reports = await engine.tick()
            #expect(reports[0].notices.contains { notice in
                if case .childrenMinted(let card, let count) = notice { return card == "c-child" && count == 2 }
                return false
            })
            // Children placed in their target columns via legal edges, lineage stamped.
            let kids = try await store.cards(boardID: doc.id).filter { $0.parentID == "c-child" }
            #expect(kids.count == 2)
            #expect(kids.allSatisfy { $0.generation == 2 && $0.birthEdgeID != nil })
            #expect(kids.allSatisfy { $0.columnID == "work" })
            // The parent did NOT transition — it waits for its children.
            #expect(try await store.getCard(id: "c-child", boardID: doc.id)!.columnID == "entry")
        }

        @Test("verb 2: defective children are re-asked once, then structured failure")
        func contractValidation() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            let doc = board()
            try await seed(doc, store)
            executor.outcomes = ["c-child": "started"]

            // First generation: empty goal + unreachable target → re-ask.
            judge.enqueueGeneration([
                .init(goal: "", input: .init(mode: .summary, sourceCardID: "c-child", payload: ""),
                      doneCondition: "d", targetColumnID: "nowhere", whyNext: "w"),
            ])
            // Re-ask: valid.
            judge.enqueueGeneration([
                .init(goal: "ok child", input: .init(mode: .summary, sourceCardID: "c-child", payload: ""),
                      doneCondition: "d", targetColumnID: "work", whyNext: "w"),
            ])

            let engine = KanbanAgent.KanbanEngineService(
                store: store, judge: judge, executor: executor, ownerID: "test", pollInterval: 0.05)
            _ = await engine.tick()
            #expect(judge.generationCallCount == 2)  // re-ask happened
            let kids = try await store.cards(boardID: doc.id).filter { $0.parentID == "c-child" }
            #expect(kids.count == 1)

        }

        @Test("verb 2: a double contract failure is a structured error, not a silent drop")
        func contractDoubleFailure() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            let doc = board()
            try await seed(doc, store)
            executor.outcomes = ["c-child": "started"]
            judge.enqueueGeneration([
                .init(goal: "", input: .init(mode: .summary, sourceCardID: "c-child", payload: ""),
                      doneCondition: "d", targetColumnID: "work", whyNext: "w"),
            ])
            judge.enqueueGeneration([
                .init(goal: "   ", input: .init(mode: .summary, sourceCardID: "c-child", payload: ""),
                      doneCondition: "d", targetColumnID: "work", whyNext: "w"),
            ])
            let engine = KanbanAgent.KanbanEngineService(
                store: store, judge: judge, executor: executor, ownerID: "test", pollInterval: 0.05)
            let reports = await engine.tick()
            #expect(judge.generationCallCount == 2)
            #expect(reports[0].notices.contains { notice in
                if case .generationFailed(let card, let reason) = notice {
                    return card == "c-child" && reason.contains("rejected twice")
                }
                return false
            })
            // Nothing minted, and the parent's own transition still consumed
            // the result — the tree is never wedged by a bad judge.
            let kids = try await store.cards(boardID: doc.id).filter { $0.parentID == "c-child" }
            #expect(kids.isEmpty)
            #expect(try await store.getCard(id: "c-child", boardID: doc.id)!.columnID == "work")
        }

        @Test("verb 2: mint allowance exhausted forces the evaluation, not an error")
        func allowanceExhausted() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = board()
            doc.settings.mintAllowance = 1  // the existing child spends it
            try await seed(doc, store)
            executor.outcomes = ["c-child": "started"]

            let engine = KanbanAgent.KanbanEngineService(
                store: store, judge: judge, executor: executor, ownerID: "test", pollInterval: 0.05)
            let reports = await engine.tick()
            #expect(judge.generationCallCount == 0)  // never asked
            #expect(reports[0].notices.contains { notice in
                if case .generationFailed(let card, let reason) = notice {
                    return card == "c-child" && reason.contains("allowance exhausted")
                }
                return false
            })
            // The parent still transitions normally.
            #expect(try await store.getCard(id: "c-child", boardID: doc.id)!.columnID == "work")
        }

        @Test("green root refuses resume; yellow root resumes at the head")
        func greenRefusesResume() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = board()
            doc.roots.append(.init(id: "r2", title: "second", definitionOfDone: "x", state: .running, firstCardID: "c2"))
            doc.roots[0].state = .green
            doc.roots[0].evidence = .init(entries: [.init(clause: "clause A", cardIDs: [], reasoning: "r")])
            try await store.saveBoard(doc)

            let engine = KanbanAgent.KanbanEngineService(
                store: store, judge: judge, executor: executor, ownerID: "test", pollInterval: 0.05)
            await #expect(throws: Error.self) {
                try await engine.resume(rootID: "r1", boardID: doc.id, context: nil)
            }
            // The yellow root r2 resumes fine — and a root event is appended.
            try await engine.resume(rootID: "r2", boardID: doc.id, context: "here is the credential")
            let saved = try await store.getBoard(id: doc.id)!
            #expect(saved.roots.first?.id == "r2")
            let events = try await store.events(boardID: doc.id, after: 0, limit: 100)
            #expect(events.contains { $0.payload.contains("here is the credential") })
        }

        @Test("resume context reaches the next evaluation request")
        func resumeContextFlows() async throws {
            let store = makeStore()
            let judge = KanbanAgent.ScriptedKanbanJudge()
            let executor = ScriptedExecutor()
            var doc = board()
            doc.roots[0].state = .yellow
            doc.roots[0].missingReport = .init(
                attempts: [.init(cardID: "c-root", whatWasTried: "everything", outcome: "blocked")],
                blockingUnknown: "the API key", userMustProvide: .credential("api key"),
                alternativesConsidered: ["asking twice"])
            try await seed(doc, store)

            let engine = KanbanAgent.KanbanEngineService(
                store: store, judge: judge, executor: executor, ownerID: "test", pollInterval: 0.05)
            try await engine.resume(rootID: "r1", boardID: doc.id, context: "key is in vault item 7")
            // Next tick: the root is running again; the deepest runnable is
            // the child; the evaluation (with resumeContext) comes later —
            // enqueue a transition for the child first.
            judge.enqueueTransition(.init(edgeID: "e12", reasoning: "ask"))
            _ = await engine.tick()
            // Evaluate the root (nothing runnable): the judge sees the context.
            judge.enqueueVerdict(.continue)
            _ = await engine.tick()
            #expect(judge.evaluationCalls.last?.root.resumeContext == "key is in vault item 7")
        }

        @Test("the LLM judge parses fenced JSON and maps verdicts")
        func llmJudgeParsing() async throws {
            final class MockClient: LLMClient, @unchecked Sendable {
                var reply = ""
                func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
                    .init(content: reply)
                }
                func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
                    .init(unfolding: { nil })
                }
                func stream(messages: [Message], tools: [[String: Any]]?, reasoningEffort: String?) -> AsyncThrowingStream<LLMDelta, Error> {
                    .init(unfolding: { nil })
                }
            }
            let client = MockClient()
            let judge = KanbanAgent.LLMKanbanJudge(client: client, model: "mock")

            // Transition: fenced JSON with prose wrapper.
            client.reply = "Sure! ```json\n{\"edgeID\": \"e4\", \"reasoning\": \"blocked\"}\n```"
            let decision = try await judge.chooseTransition(.init(
                card: KanbanAgent.Card(id: "c", laneID: "l", columnID: "work", goal: "g", doneCondition: "d", parentID: nil, rootID: "r"),
                result: .init(outcome: "x", summary: "s"),
                legalEdges: [], subtree: [], definitionOfDone: "dod"))
            #expect(decision.edgeID == "e4")

            // Verdict: continue / green / yellow.
            client.reply = "{\"verdict\": \"continue\"}"
            if case .continue = try await judge.evaluateRoot(.init(
                root: .init(id: "r", title: "t", definitionOfDone: "d", state: .running, firstCardID: "c"),
                tree: [], mintedChildren: 0, maxDepth: 8)) {} else {
                Issue.record("expected continue")
            }

            client.reply = """
            {"verdict": "green", "evidence": [{"clause": "clause A", "cardIDs": ["c1"], "reasoning": "r"}]}
            """
            if case .green(let chain) = try await judge.evaluateRoot(.init(
                root: .init(id: "r", title: "t", definitionOfDone: "d", state: .running, firstCardID: "c"),
                tree: [], mintedChildren: 0, maxDepth: 8)) {
                #expect(chain.entries.count == 1)
                #expect(chain.entries[0].clause == "clause A")
            } else {
                Issue.record("expected green")
            }

            client.reply = """
            {"verdict": "yellow", "attempts": [{"cardID": "c1", "whatWasTried": "x", "outcome": "y"}],
             "blockingUnknown": "the key", "provision": {"kind": "credential", "detail": "api key"},
             "alternativesConsidered": ["a"]}
            """
            if case .yellow(let report) = try await judge.evaluateRoot(.init(
                root: .init(id: "r", title: "t", definitionOfDone: "d", state: .running, firstCardID: "c"),
                tree: [], mintedChildren: 0, maxDepth: 8)) {
                #expect(report.blockingUnknown == "the key")
                #expect(report.userMustProvide == .credential("api key"))
            } else {
                Issue.record("expected yellow")
            }
        }
    }
}
