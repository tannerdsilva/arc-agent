import Testing
import Foundation
@testable import ArcAgentCore

/// LIVE wire test against the running daemon (127.0.0.1:8080).
/// Requires ARC_KANBAN_PROXY_TOKEN in the environment; skips (with a
/// loud marker in the output) otherwise. Writes to the `live-test`
/// board on the daemon's real store.
@Suite("Card proxy live wire", .enabled(if: ProcessInfo.processInfo.environment["ARC_KANBAN_PROXY_TOKEN"] != nil))
struct CardProxyLiveTests {

    private func liveProxy() -> ProxiedCardStore {
        let token = ProcessInfo.processInfo.environment["ARC_KANBAN_PROXY_TOKEN"]!
        return ProxiedCardStore(host: "127.0.0.1", port: 8080, token: token)
    }

    @Test("every verb round-trips over the live daemon")
    func verbMatrix() async throws {
        let proxy = try liveProxy()
        let board = "live-test"

        // create + read
        let created = try await proxy.createTask(
            CardTask(id: "lt-1", title: "Live wire task", body: "written by CardProxyLiveTests"),
            board: board)
        #expect(created.id == "lt-1")
        let fetched = try await proxy.getTask(id: "lt-1", board: board)
        #expect(fetched?.title == "Live wire task")

        // list
        let listed = try await proxy.listTasks(board: board, filter: CardListFilter())
        #expect(listed.contains { $0.id == "lt-1" })

        // claim + heartbeat + run list
        let (claimed, run) = try await proxy.claimTask(id: "lt-1", board: board, profile: "live-tester")
        #expect(claimed.id == "lt-1")
        try await proxy.heartbeat(id: "lt-1", board: board, runID: run.id)
        let runs = try await proxy.runs(taskID: "lt-1", board: board)
        #expect(runs.contains { $0.id == run.id })

        // second task + link
        _ = try await proxy.createTask(CardTask(id: "lt-2", title: "Child"), board: board)
        try await proxy.link(parentID: "lt-1", childID: "lt-2", board: board)
        #expect(try await proxy.parentIDs(of: "lt-2", board: board) == ["lt-1"])
        #expect(try await proxy.childIDs(of: "lt-1", board: board) == ["lt-2"])

        // comments + attachments + events
        _ = try await proxy.addComment(taskID: "lt-1", board: board, author: "live-test", body: "hello over the wire")
        #expect(try await proxy.comments(taskID: "lt-1", board: board).contains { $0.body == "hello over the wire" })
        _ = try await proxy.attach(taskID: "lt-1", board: board, filename: "probe.txt", contentType: "text/plain", data: Data("probe".utf8))
        #expect(try await proxy.attachments(taskID: "lt-1", board: board).contains { $0.filename == "probe.txt" })
        try await proxy.appendEvent(taskID: "lt-1", board: board, runID: nil, kind: "note", payload: "live probe")
        #expect(try await proxy.events(taskID: "lt-1", board: board, limit: 10).contains { $0.kind == "note" })

        // save + complete
        var edited = claimed
        edited.title = "Live wire task (edited)"
        try await proxy.saveTask(edited, board: board)
        #expect(try await proxy.getTask(id: "lt-1", board: board)?.title == "Live wire task (edited)")

        let (completed, doneRun) = try await proxy.completeTask(
            id: "lt-1", board: board, runID: run.id, summary: "live-test handoff",
            metadata: nil, createdCards: [], artifacts: [])
        #expect(completed.status == .done)
        #expect(doneRun.id == run.id)
        #expect(try await proxy.getTask(id: "lt-1", board: board)?.result == "live-test handoff")
    }
}
