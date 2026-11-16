import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Kanban agent phase 2: column graph (spec 02)

extension ArcCoreTestRoot {

    @Suite("Kanban agent graph", .serialized)
    struct KanbanAgentGraphTests {

        // Fixture: entry --det(ok)--> work --policy--> review/terminal
        //          work --ask--> human; work --self--> work (retry cycle)
        private func fixtureGraph() -> KanbanAgent.BoardGraph {
            let entry = KanbanAgent.Column(id: "entry", name: "Entry", kind: .agentWork, isTriage: false)
            let work = KanbanAgent.Column(id: "work", name: "Work", kind: .agentWork, isTriage: true)
            let review = KanbanAgent.Column(id: "review", name: "Review", kind: .agentWork)
            let done = KanbanAgent.Column(id: "done", name: "Done", kind: .terminal)
            let human = KanbanAgent.Column(id: "human", name: "Ask", kind: .humanWait)
            let columns = [entry, work, review, done, human]
            let edges: [KanbanAgent.Edge] = [
                .init(id: "e1", fromColumnID: "entry", toColumnID: "work", decision: .deterministic, outcomeLabel: "started"),
                .init(id: "e2", fromColumnID: "work", toColumnID: "review", decision: .policy, policy: .agent),
                .init(id: "e3", fromColumnID: "review", toColumnID: "done", decision: .deterministic, outcomeLabel: "approved"),
                .init(id: "e4", fromColumnID: "work", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
                .init(id: "e5", fromColumnID: "work", toColumnID: "work", decision: .policy, policy: .counter),
                .init(id: "e6", fromColumnID: "human", toColumnID: "work", decision: .policy, policy: .fixed),
                .init(id: "e12", fromColumnID: "entry", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
                .init(id: "e13", fromColumnID: "review", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true),
            ]
            return .init(columns: columns, edges: edges)
        }

        @Test("fixture graph is valid")
        func validFixture() {
            #expect(fixtureGraph().validate().isEmpty)
        }

        @Test("accessors: fan-out, fan-in, cycles, exact outcome match")
        func accessors() {
            let graph = fixtureGraph()
            #expect(graph.edges(from: "work").count == 3)
            #expect(graph.policyEdges(from: "work").map(\.id) == ["e2", "e4", "e5"])
            #expect(graph.deterministicEdge(from: "entry", outcome: "started")?.id == "e1")
            #expect(graph.deterministicEdge(from: "entry", outcome: "Started") == nil) // exact match only
            #expect(graph.deterministicEdge(from: "work", outcome: "started") == nil)  // per-column
            #expect(graph.askTheUserEdge(from: "work")?.id == "e4")
            #expect(graph.askTheUserEdge(from: "human") == nil) // the destination cannot ask
            #expect(graph.entryColumns().map(\.id) == ["entry"])
            #expect(graph.terminalColumns().map(\.id) == ["done"])
            #expect(graph.humanWaitColumn()?.id == "human")
        }

        @Test("rule 1: orphan column is a warning")
        func orphan() {
            var graph = fixtureGraph()
            graph.columns.append(.init(id: "orphan", name: "Orphan", kind: .agentWork))
            let violations = graph.validate()
            #expect(violations.contains(.orphanColumn(columnID: "orphan")))
            #expect(violations.first { $0 == .orphanColumn(columnID: "orphan") }!.isWarning)
        }

        @Test("rule 2: reachable dead end is a warning")
        func deadEnd() {
            var graph = fixtureGraph()
            // review loses all outgoing edges; still reachable from work.
            graph.edges.removeAll { $0.id == "e3" || $0.id == "e13" }
            let violations = graph.validate()
            #expect(violations.contains(.deadEndColumn(columnID: "review")))
        }

        @Test("rule 3: missing triage is hard")
        func missingTriage() {
            var graph = fixtureGraph()
            graph.columns = graph.columns.map { col in
                var c = col
                c.isTriage = false
                return c
            }
            #expect(graph.validate().contains(.missingTriage))
            #expect(!graph.validate().first { $0 == .missingTriage }!.isWarning)
        }

        @Test("rule 4: column without ask-the-user edge is hard")
        func missingAsk() {
            var graph = fixtureGraph()
            graph.edges.removeAll { $0.id == "e4" }
            #expect(graph.validate().contains(.missingAskTheUser(columnID: "work")))
        }

        @Test("rule 4 target: ask edge must land on the humanWait column")
        func askTarget() {
            var graph = fixtureGraph()
            graph.edges.removeAll { $0.id == "e4" }
            graph.edges.append(.init(id: "e4", fromColumnID: "work", toColumnID: "review", decision: .policy, policy: .agent, isAskTheUser: true))
            #expect(graph.validate().contains(.askTheUserTargetInvalid(edgeID: "e4")))
        }

        @Test("rule 5: terminal with outgoing is hard")
        func terminalOutgoing() {
            var graph = fixtureGraph()
            graph.edges.append(.init(id: "e7", fromColumnID: "done", toColumnID: "work", decision: .deterministic, outcomeLabel: "reopen"))
            #expect(graph.validate().contains(.terminalWithOutgoing(columnID: "done")))
        }

        @Test("rules 6/7/8: dangling and mislabeled edges are hard")
        func edgeShape() {
            var graph = fixtureGraph()
            graph.edges.append(.init(id: "e8", fromColumnID: "work", toColumnID: "ghost", decision: .policy, policy: .agent))
            graph.edges.append(.init(id: "e9", fromColumnID: "review", toColumnID: "done", decision: .deterministic))
            graph.edges.append(.init(id: "e10", fromColumnID: "review", toColumnID: "done", decision: .policy, policy: .agent, outcomeLabel: "nope"))
            let violations = graph.validate()
            #expect(violations.contains(.danglingEdge(edgeID: "e8")))
            #expect(violations.contains(.deterministicWithoutLabel(edgeID: "e9")))
            #expect(violations.contains(.policyWithLabel(edgeID: "e10")))
        }

        @Test("rule 9: two ask edges from one column is hard")
        func doubleAsk() {
            var graph = fixtureGraph()
            graph.edges.append(.init(id: "e11", fromColumnID: "entry", toColumnID: "human", decision: .policy, policy: .agent, isAskTheUser: true))
            #expect(graph.validate().contains(.multipleAskTheUser(columnID: "entry")))
        }

        @Test("cycle-only graph: every column is an entry, no orphans")
        func cycleOnly() {
            let a = KanbanAgent.Column(id: "a", name: "A", kind: .agentWork, isTriage: true)
            let b = KanbanAgent.Column(id: "b", name: "B", kind: .agentWork)
            let human = KanbanAgent.Column(id: "h", name: "H", kind: .humanWait)
            let graph = KanbanAgent.BoardGraph(
                columns: [a, b, human],
                edges: [
                    .init(id: "x1", fromColumnID: "a", toColumnID: "b", decision: .policy, policy: .agent),
                    .init(id: "x2", fromColumnID: "b", toColumnID: "a", decision: .policy, policy: .agent),
                    .init(id: "x3", fromColumnID: "a", toColumnID: "h", decision: .policy, policy: .agent, isAskTheUser: true),
                    .init(id: "x4", fromColumnID: "b", toColumnID: "h", decision: .policy, policy: .agent, isAskTheUser: true),
                    .init(id: "x5", fromColumnID: "h", toColumnID: "a", decision: .policy, policy: .fixed),
                ])
            let violations = graph.validate()
            #expect(!violations.contains(.orphanColumn(columnID: "a")))
            #expect(!violations.contains(.orphanColumn(columnID: "b")))
        }

        // MARK: Editing protocol

        private func board() -> KanbanAgent.BoardDocument {
            var board = KanbanAgent.BoardDocument(id: "b", name: "B")
            let graph = fixtureGraph()
            board.columns = graph.columns
            board.edges = graph.edges
            return board
        }

        @Test("apply: add + rename + setKind + removeEdge, revision bumps")
        func applyBasics() throws {
            var doc = board()
            #expect(try KanbanAgent.BoardGraphEditor.apply(
                .addColumn(.init(id: "new", name: "New", kind: .agentWork)), to: &doc, occupiedColumns: []).isEmpty == false)
            // new column has no edges → warnings expected, revision bumped
            #expect(doc.revision == 1)

            try KanbanAgent.BoardGraphEditor.apply(.renameColumn(id: "new", name: "Renamed"), to: &doc, occupiedColumns: [])
            #expect(doc.columns.first { $0.id == "new" }?.name == "Renamed")

            try KanbanAgent.BoardGraphEditor.apply(.setKind(id: "new", kind: .terminal), to: &doc, occupiedColumns: [])
            #expect(doc.columns.first { $0.id == "new" }?.kind == .terminal)

            try KanbanAgent.BoardGraphEditor.apply(.removeEdge(id: "e5"), to: &doc, occupiedColumns: [])
            #expect(!doc.edges.contains { $0.id == "e5" })
            #expect(doc.revision == 4)
        }

        @Test("apply: removeColumn refused while cards occupy it")
        func removeOccupied() {
            var doc = board()
            #expect(throws: KanbanAgent.GraphEditError.columnOccupied(columnID: "work")) {
                try KanbanAgent.BoardGraphEditor.apply(.removeColumn(id: "work"), to: &doc, occupiedColumns: ["work"])
            }
            #expect(doc.revision == 0) // refused edits do not bump
        }

        @Test("apply: role columns (triage, humanWait) are protected")
        func roleProtection() {
            var doc = board()
            #expect(throws: KanbanAgent.GraphEditError.roleColumnProtected(columnID: "human", role: "humanWait")) {
                try KanbanAgent.BoardGraphEditor.apply(.removeColumn(id: "human"), to: &doc, occupiedColumns: [])
            }
            var triageDoc = board()
            #expect(throws: KanbanAgent.GraphEditError.roleColumnProtected(columnID: "work", role: "triage")) {
                try KanbanAgent.BoardGraphEditor.apply(.removeColumn(id: "work"), to: &triageDoc, occupiedColumns: [])
            }
        }

        @Test("apply: removing a plain column cascades its edges and stays runnable")
        func removePlain() throws {
            var doc = board()
            // "review" is not a role column and unoccupied.
            let violations = try KanbanAgent.BoardGraphEditor.apply(.removeColumn(id: "review"), to: &doc, occupiedColumns: [])
            #expect(!doc.columns.contains { $0.id == "review" })
            #expect(!doc.edges.contains { $0.id == "e2" || $0.id == "e3" || $0.id == "e13" })
            // "done" loses its only incoming edge (e3) → now unreachable: a
            // warning, not a refusal — the user may be mid-shape.
            #expect(violations == [.orphanColumn(columnID: "done")])
        }
    }
}
