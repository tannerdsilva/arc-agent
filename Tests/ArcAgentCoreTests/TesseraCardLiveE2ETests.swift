import Foundation
import Testing
@testable import ArcAgentCore

// ==========================================================================
// TesseraCardStore — live round-trip against the configured relay.
//
// Gated: runs only with ARC_CARD_TESSERA_E2E=1 (and a configured tessera
// block), because it writes real events to the real relay. A normal
// `swift test` never touches the network.
//
// Provenance note: the local relay's write-echo latency currently exceeds
// the client's 5s bound and its read fan-out serves 0 events (the known
// relay-side wedge). Card writes DO land (kind 3014 scribed in
// peer-transactions.jsonl); this suite exists so the full read/write
// round-trip can be proven the moment the relay heals:
//     ARC_CARD_TESSERA_E2E=1 swift test --filter TesseraCardLiveE2E
// ==========================================================================

let cardLiveGate = ProcessInfo.processInfo.environment["ARC_CARD_TESSERA_E2E"] == "1"
    && loadConfig().tessera != nil

@Suite("TesseraCardStore live E2E", .serialized, .disabled(if: !cardLiveGate))
struct TesseraCardLiveE2E {

    @Test("live round-trip: create → claim → complete → runs, on the real relay")
    func liveRoundTrip() async throws {
        let cfg = try #require(loadConfig().tessera)
        await TesseraConnection.shared.configure(cfg)

        let store = TesseraCardStore()
        let board = "e2e-live-\(UUID().uuidString.prefix(6))"

        // create
        let task = try await store.createTask(
            CardTask(title: "live round-trip", body: "tessera e2e", priority: 1),
            board: board)
        #expect(task.status == .ready)

        // claim → run exists, task running
        let (claimed, run) = try await store.claimTask(id: task.id, board: board, profile: "e2e")
        #expect(claimed.status == .running)
        #expect(run.attempt == 1)

        // complete
        let (done, closed) = try await store.completeTask(
            id: task.id, board: board, runID: run.id,
            summary: "tessera live round-trip", metadata: ["suite": "TesseraCardLiveE2E"],
            createdCards: [], artifacts: [])
        #expect(done.status == .done)
        #expect(closed.outcome == .completed)

        // reads agree
        #expect(try await store.getTask(id: task.id, board: board)?.status == .done)
        #expect(try await store.runs(taskID: task.id, board: board).count == 1)
        #expect(try await store.events(taskID: task.id, board: board, limit: 20).map(\.kind).contains("completed"))

        // clean the probe board
        try await store.deleteBoard(board: board)
        #expect(try await store.getTask(id: task.id, board: board) == nil)
    }
}
