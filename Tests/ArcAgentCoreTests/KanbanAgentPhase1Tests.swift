import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Kanban agent phase 1: domain model + storage (specs 01, 03)

private func fixtureBoard(id: String = "b1", revision: Int = 0) -> KanbanAgent.BoardDocument {
    var board = KanbanAgent.BoardDocument(id: id, name: "Test")
    board.revision = revision
    return board
}

private func fixtureCard(rootID: String, columnID: String = "col-1", laneID: String = "lane-1") -> KanbanAgent.Card {
    KanbanAgent.Card(
        laneID: laneID, columnID: columnID, goal: "do the thing",
        doneCondition: "the thing is done", parentID: nil, rootID: rootID, generation: 0)
}

extension ArcCoreTestRoot {

    @Suite("Kanban agent model", .serialized)
    struct KanbanAgentModelTests {

        @Test("validation passes for a well-formed card")
        func validCard() {
            let lane = KanbanAgent.Lane(id: "lane-1", name: "L1")
            let column = KanbanAgent.Column(id: "col-1", name: "Todo", kind: .agentWork)
            let root = KanbanAgent.Root(id: "r1", title: "T", definitionOfDone: "- a\n- b", firstCardID: "c1")
            let card = fixtureCard(rootID: "r1")
            #expect(card.validate(lanes: [lane], columns: [column], roots: [root], cards: [card]).isEmpty)
        }

        @Test("lineage: unknown parent, cross-root parent, missing input")
        func lineageValidation() {
            let root1 = KanbanAgent.Root(id: "r1", title: "T", definitionOfDone: "x", firstCardID: "c1")
            let root2 = KanbanAgent.Root(id: "r2", title: "T2", definitionOfDone: "y", firstCardID: "c2")
            let parent = fixtureCard(rootID: "r1")
            var parentMut = parent
            parentMut.readiness = .done
            parentMut.result = .init(outcome: "ok", summary: "s")

            var child = KanbanAgent.Card(
                laneID: "lane-1", columnID: "col-1", goal: "g", doneCondition: "d",
                parentID: parent.id, rootID: "r1", birthEdgeID: "e1", generation: 1)
            #expect(child.validate(lanes: [], columns: [], roots: [root1], cards: [parentMut])
                .contains(.missingInput(cardID: child.id)))

            child.input = .init(mode: .reference, sourceCardID: "someone-else", payload: "x")
            #expect(child.validate(lanes: [], columns: [], roots: [root1], cards: [parentMut])
                .contains(.inputNotFromParent(cardID: child.id)))

            let crossRoot = KanbanAgent.Card(
                laneID: "lane-1", columnID: "col-1", goal: "g", doneCondition: "d",
                parentID: parent.id, rootID: "r2", generation: 1)
            #expect(crossRoot.validate(lanes: [], columns: [], roots: [root2], cards: [parentMut])
                .contains(.crossRootParent(cardID: crossRoot.id, parentID: parent.id)))

            let orphan = KanbanAgent.Card(
                laneID: "lane-1", columnID: "col-1", goal: "g", doneCondition: "d",
                parentID: "ghost", rootID: "r1", generation: 1)
            #expect(orphan.validate(lanes: [], columns: [], roots: [root1], cards: [parentMut])
                .contains(.unknownParent(cardID: orphan.id, parentID: "ghost")))
        }

        @Test("done without result is invalid; empty contract is invalid")
        func contractValidation() {
            let root = KanbanAgent.Root(id: "r1", title: "T", definitionOfDone: "x", firstCardID: "c1")
            var card = fixtureCard(rootID: "r1")
            card.readiness = .done
            #expect(card.validate(lanes: [], columns: [], roots: [root], cards: [card])
                .contains(.doneWithoutResult(cardID: card.id)))

            card.result = .init(outcome: "ok", summary: "s")
            card.goal = "   "
            #expect(card.validate(lanes: [], columns: [], roots: [root], cards: [card])
                .contains(.emptyGoal(cardID: card.id)))

            card.goal = "g"
            card.doneCondition = ""
            #expect(card.validate(lanes: [], columns: [], roots: [root], cards: [card])
                .contains(.emptyDoneCondition(cardID: card.id)))
        }

        @Test("column kind-dependent fields must match the kind")
        func columnKindValidation() {
            var timer = KanbanAgent.Column(id: "c", name: "Wait", kind: .timerWait, timerSeconds: nil)
            #expect(timer.validate() == .columnKindMismatch(columnID: "c"))
            timer.timerSeconds = 60
            #expect(timer.validate() == nil)

            let terminal = KanbanAgent.Column(id: "t", name: "Done", kind: .terminal, defaultEdgeID: "e1")
            #expect(terminal.validate() == .columnKindMismatch(columnID: "t"))
        }

        @Test("Codable round-trip preserves the full model")
        func codableRoundTrip() throws {
            var board = KanbanAgent.BoardDocument(
                id: "b", name: "B",
                lanes: [.init(id: "l", name: "Lane")],
                columns: [.init(id: "c", name: "Col", kind: .timerWait, timerSeconds: 30)],
                edges: [.init(fromColumnID: "c", toColumnID: "c2", decision: .policy, policy: .agent)],
                roots: [.init(id: "r", title: "T", definitionOfDone: "- one", firstCardID: "card")])
            board.settings = .init(profile: "kanban", cycleBudget: 5)
            board.revision = 3

            let data = try JSONEncoder().encode(board)
            let back = try JSONDecoder().decode(KanbanAgent.BoardDocument.self, from: data)
            #expect(back == board)
            #expect(back.schemaVersion == KanbanAgent.BoardDocument.schemaVersion)
        }

        @Test("board settings defaults match the spec (decision 8)")
        func settingsDefaults() {
            let s = KanbanAgent.BoardSettings.default
            #expect(s.profile == nil)
            #expect(s.cycleBudget == 3)
            #expect(s.maxDepth == 8)
            #expect(s.mintAllowance == 25)
            #expect(s.staleMotionTimeoutSeconds == 600)
            #expect(s.triageCooldownSeconds == 300)
        }
    }

    @Suite("Kanban agent file store", .serialized)
    struct KanbanAgentFileStoreTests {

        private func makeStore() -> FileKanbanAgentStore {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-kanban-tests-\(UUID().uuidString)", isDirectory: true)
            return FileKanbanAgentStore(root: dir)
        }

        @Test("conformance: board, cards, events, delete round-trips")
        func roundTrip() async throws {
            let store = makeStore()
            try await store.saveBoard(fixtureBoard())
            try await store.saveBoard(fixtureBoard(id: "b1", revision: 1).renamed("Renamed"))

            let fetched = try await store.getBoard(id: "b1")
            #expect(fetched?.name == "Renamed")
            #expect(fetched?.revision == 1)

            let card = fixtureCard(rootID: "r1")
            try await store.saveCard(card, boardID: "b1")
            let fetchedCard = try await store.getCard(id: card.id, boardID: "b1")
            #expect(fetchedCard == card)
            #expect(try await store.cards(boardID: "b1").count == 1)

            try await store.appendEvent(.init(seq: 1, kind: .cardCreate, payload: "{}"), boardID: "b1")
            try await store.appendEvent(.init(seq: 2, kind: .transition, payload: "{}"), boardID: "b1")
            let events = try await store.events(boardID: "b1", after: 0, limit: 10)
            #expect(events.count == 2)
            #expect(try await store.events(boardID: "b1", after: 1, limit: 10).count == 1)

            try await store.deleteBoard(id: "b1")
            #expect(try await store.getBoard(id: "b1") == nil)
            #expect(try await store.cards(boardID: "b1").isEmpty)
        }

        @Test("revision gate: stale writers are refused")
        func revisionGate() async throws {
            let store = makeStore()
            try await store.saveBoard(fixtureBoard())

            do {
                var stale = fixtureBoard(revision: 0)
                stale.name = "stale"
                try await store.saveBoard(stale)
                Issue.record("expected revisionConflict")
            } catch let error as KanbanAgentStoreError {
                #expect(error == .revisionConflict(expected: 1, got: 0))
            }

            do {
                let skip = fixtureBoard(revision: 5)
                try await store.saveBoard(skip)
                Issue.record("expected revisionConflict")
            } catch let error as KanbanAgentStoreError {
                #expect(error == .revisionConflict(expected: 1, got: 5))
            }
        }

        @Test("event sequence gate: gaps and rewrites are refused")
        func eventSequenceGate() async throws {
            let store = makeStore()
            try await store.saveBoard(fixtureBoard())
            try await store.appendEvent(.init(seq: 1, kind: .cardCreate, payload: "{}"), boardID: "b1")

            do {
                try await store.appendEvent(.init(seq: 3, kind: .transition, payload: "{}"), boardID: "b1")
                Issue.record("expected eventSequenceConflict")
            } catch let error as KanbanAgentStoreError {
                #expect(error == .eventSequenceConflict(expected: 2, got: 3))
            }
        }

        @Test("operations on a missing board fail legibly")
        func missingBoard() async throws {
            let store = makeStore()
            #expect(try await store.getBoard(id: "nope") == nil)
            do {
                try await store.saveCard(fixtureCard(rootID: "r"), boardID: "nope")
                Issue.record("expected boardNotFound")
            } catch let error as KanbanAgentStoreError {
                #expect(error == .boardNotFound("nope"))
            }
            do {
                try await store.deleteBoard(id: "nope")
                Issue.record("expected boardNotFound")
            } catch let error as KanbanAgentStoreError {
                #expect(error == .boardNotFound("nope"))
            }
        }
    }

    @Suite("Kanban agent tessera helpers", .serialized)
    struct KanbanAgentTesseraTests {

        private func record(_ dTag: String, _ payload: some Codable) -> TesseraRecord {
            TesseraRecord(id: nil, dTag: dTag, content: String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self))
        }

        @Test("dTag shapes")
        func dTagShapes() {
            #expect(TesseraKanbanAgentStore.boardDTag(boardID: "b1", seq: 7) == "arc/kb/board/b1/7")
            #expect(TesseraKanbanAgentStore.cardDTag(boardID: "b1", cardID: "c1", seq: 8) == "arc/kb/board/b1/card/c1/8")
            #expect(TesseraKanbanAgentStore.eventDTag(boardID: "b1", seq: 9) == "arc/kb/board/b1/evt/9")
        }

        @Test("latestBoards: newest document per board id wins; card/evt dTags ignored")
        func latestBoards() {
            let old = fixtureBoard(id: "b1"); var newer = fixtureBoard(id: "b1"); newer.name = "new"
            let other = fixtureBoard(id: "b2")
            let records = [
                record("arc/kb/board/b1/1", old),
                record("arc/kb/board/b1/9", newer),
                record("arc/kb/board/b2/2", other),
                record("arc/kb/board/b1/card/c1/3", fixtureCard(rootID: "r")),
            ]
            let boards = TesseraKanbanAgentStore.latestBoards(from: records)
            #expect(boards.count == 2)
            #expect(boards["b1"]?.name == "new")
            #expect(boards["b2"] != nil)
        }

        @Test("latestCards: highest seq per card prefix wins across boards")
        func latestCards() {
            let card = fixtureCard(rootID: "r1")
            var updated = card
            updated.goal = "updated"
            let records = [
                record("arc/kb/board/b1/card/\(card.id)/1", card),
                record("arc/kb/board/b1/card/\(card.id)/5", updated),
                record("arc/kb/board/b2/card/\(card.id)/2", card),
                record("arc/kb/board/b1/evt/3", KanbanAgent.BoardEvent(seq: 3, kind: .transition, payload: "{}")),
            ]
            let cards = TesseraKanbanAgentStore.latestCards(from: records)
            #expect(cards["b1"]?[card.id]?.goal == "updated")
            #expect(cards["b2"]?[card.id] != nil)
            #expect(cards.count == 2)
        }

        @Test("eventHeads: highest seq per board; boardID extraction")
        func eventHeadHelpers() {
            let records = [
                record("arc/kb/board/b1/evt/3", "{}"),
                record("arc/kb/board/b1/evt/7", "{}"),
                record("arc/kb/board/b2/evt/2", "{}"),
            ]
            let heads = TesseraKanbanAgentStore.eventHeads(from: records)
            #expect(heads["b1"] == 7)
            #expect(heads["b2"] == 2)

            #expect(TesseraKanbanAgentStore.boardID(fromCardDTag: "arc/kb/board/b1/card/c1/8") == "b1")
            #expect(TesseraKanbanAgentStore.boardID(fromCardDTag: "arc/kb/board/b1/evt/8") == nil)
            #expect(TesseraKanbanAgentStore.sequence(fromEventDTag: "arc/kb/board/b1/evt/42") == 42)
            #expect(TesseraKanbanAgentStore.sequence(fromEventDTag: "arc/kb/board/b1/card/c/8") == nil)
        }
    }
}

extension KanbanAgent.BoardDocument {
    /// Test helper: rename and return self (keeps fixtures terse).
    fileprivate func renamed(_ name: String) -> KanbanAgent.BoardDocument {
        var copy = self
        copy.name = name
        return copy
    }
}
