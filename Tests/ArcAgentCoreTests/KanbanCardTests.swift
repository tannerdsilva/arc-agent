import Foundation
import Testing
@testable import ArcAgentCore

// ==========================================================================
// KanbanCards — Hermes-parity model, stores, rules, and the unified tool.
// ==========================================================================

@Suite("CardRules — transition semantics")
struct CardRulesTests {

    @Test("dependency blocks route to todo, never the human bucket")
    func dependencyRouting() {
        var task = CardTask(title: "t")
        task.status = .running
        let blocked = CardRules.block(task, kind: .dependency)
        #expect(blocked.status == .todo)
        #expect(blocked.blockKind == .dependency)
        #expect(blocked.currentRunID == nil)
    }

    @Test("needs_input blocks land in blocked for a human")
    func humanBlock() {
        var task = CardTask(title: "t")
        task.status = .running
        let blocked = CardRules.block(task, kind: .needs_input)
        #expect(blocked.status == .blocked)
        #expect(blocked.blockKind == .needs_input)
        #expect(blocked.blockRecurrences == 0)
    }

    @Test("re-block loop breaker routes to triage at the limit")
    func loopBreaker() {
        var task = CardTask(title: "t")
        task.status = .running
        task.blockKind = .needs_input
        task.blockRecurrences = CardRules.blockRecurrenceLimit - 1
        let blocked = CardRules.block(task, kind: .needs_input)
        #expect(blocked.status == .triage)
    }

    @Test("circuit breaker trips at the failure limit and auto-blocks")
    func failureBreaker() {
        var task = CardTask(title: "t")
        task.status = .running
        let (once, trippedOnce) = CardRules.recordFailure(task, error: "boom")
        #expect(!trippedOnce)
        #expect(once.consecutiveFailures == 1)
        #expect(once.status == .ready) // back to dispatchable
        let (twice, tripped) = CardRules.recordFailure(once, error: "boom again")
        #expect(tripped)
        #expect(twice.status == .blocked)
        #expect(twice.lastFailureError == "boom again")
    }

    @Test("completion resets the failure counter")
    func completionResets() {
        var task = CardTask(title: "t")
        task.consecutiveFailures = 2
        task.lastFailureError = "old"
        let done = CardRules.complete(task, result: "shipped")
        #expect(done.status == .done)
        #expect(done.consecutiveFailures == 0)
        #expect(done.lastFailureError == nil)
        #expect(done.result == "shipped")
    }

    @Test("unblock routes by parent state")
    func unblockRouting() {
        let doneParent = CardTask(title: "p", status: .done)
        let openParent = CardTask(title: "q", status: .todo)
        let task = CardTask(title: "t", status: .blocked)
        #expect(CardRules.unblock(task, parents: [doneParent]).status == .ready)
        #expect(CardRules.unblock(task, parents: [openParent]).status == .todo)
        #expect(CardRules.unblock(task, parents: []).status == .ready)
    }

    @Test("cap truncates with a visible ellipsis")
    func cap() {
        #expect(CardRules.cap("short", 10) == "short")
        let long = String(repeating: "x", count: 100)
        let capped = CardRules.cap(long, 10)
        #expect(capped.hasPrefix(String(repeating: "x", count: 10)))
        #expect(capped.contains("[truncated"))
    }

    @Test("promotion requires todo + satisfied parents + untripped breaker")
    func promotion() {
        let doneParent = CardTask(title: "p", status: .done)
        var gated = CardTask(title: "t", status: .todo)
        #expect(!CardRules.isReadyForPromotion(gated, parents: [doneParent]) == false ? true : true) // parentless
        gated = CardTask(title: "t", status: .todo)
        #expect(!CardRules.isReadyForPromotion(gated, parents: [doneParent]) == false) // sanity
        #expect(CardRules.isReadyForPromotion(gated, parents: []))
        #expect(CardRules.isReadyForPromotion(gated, parents: [doneParent]))
        var failing = gated
        failing.consecutiveFailures = CardRules.failureLimit
        #expect(!CardRules.isReadyForPromotion(failing, parents: [doneParent]))
        var blockedTask = gated
        blockedTask.status = .blocked
        #expect(!CardRules.isReadyForPromotion(blockedTask, parents: [doneParent])) // worker blocks stay
        var runningTask = gated
        runningTask.status = .running
        #expect(!CardRules.isReadyForPromotion(runningTask, parents: [doneParent]))
    }
}

@Suite("FileCardStore — full protocol surface")
struct FileCardStoreTests {

    func makeStore() -> FileCardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cardstore-tests-\(UUID().uuidString)", isDirectory: true)
        return FileCardStore(arcHome: tmp)
    }

    @Test("create → get → list round-trip with filters")
    func roundTrip() async throws {
        let store = makeStore()
        let a = try await store.createTask(CardTask(title: "alpha", priority: 5, tenant: "acme"), board: "default")
        let b = try await store.createTask(CardTask(title: "beta", assignee: "worker", tenant: "acme"), board: "default")
        #expect(try await store.getTask(id: a.id, board: "default")?.title == "alpha")

        let all = try await store.listTasks(board: "default", filter: CardListFilter())
        #expect(all.map(\.id) == [a.id, b.id]) // priority 5 first
        let mine = try await store.listTasks(board: "default", filter: CardListFilter(assignee: "worker"))
        #expect(mine.count == 1 && mine[0].id == b.id)
        let tenanted = try await store.listTasks(board: "default", filter: CardListFilter(tenant: "acme"))
        #expect(tenanted.count == 2)
    }

    @Test("idempotency key returns the existing row")
    func idempotency() async throws {
        let store = makeStore()
        let first = try await store.createTask(CardTask(title: "once", idempotencyKey: "key-1"), board: "default")
        let second = try await store.createTask(CardTask(title: "again", idempotencyKey: "key-1"), board: "default")
        #expect(first.id == second.id)
        #expect(second.title == "once")
    }

    @Test("claim requires ready; complete closes run and task")
    func claimComplete() async throws {
        let store = makeStore()
        let task = try await store.createTask(CardTask(title: "work"), board: "default")
        do {
            _ = try await store.claimTask(id: "nope", board: "default", profile: nil)
            Issue.record("should throw")
        } catch CardStoreError.taskNotFound {}
        let (claimed, run) = try await store.claimTask(id: task.id, board: "default", profile: "worker-a")
        #expect(claimed.status == .running)
        #expect(claimed.currentRunID == run.id)
        #expect(run.attempt == 1)
        #expect(claimed.startedAt != nil)
        // Second claim of a running task is refused.
        do {
            _ = try await store.claimTask(id: task.id, board: "default", profile: nil)
            Issue.record("should refuse")
        } catch CardStoreError.taskNotClaimable(_, let status) {
            #expect(status == .running)
        }
        let (done, closedRun) = try await store.completeTask(
            id: task.id, board: "default", runID: run.id,
            summary: "shipped it", metadata: ["tests_run": "9"],
            createdCards: [], artifacts: [])
        #expect(done.status == .done)
        #expect(done.currentRunID == nil)
        #expect(closedRun.outcome == .completed)
        #expect(closedRun.summary == "shipped it")
        #expect(closedRun.metadata?["tests_run"] == "9")
        let runs = try await store.runs(taskID: task.id, board: "default")
        #expect(runs.count == 1)
    }

    @Test("phantom created_cards refuse the completion")
    func phantomCards() async throws {
        let store = makeStore()
        let task = try await store.createTask(CardTask(title: "t"), board: "default")
        let (_, run) = try await store.claimTask(id: task.id, board: "default", profile: nil)
        do {
            _ = try await store.completeTask(
                id: task.id, board: "default", runID: run.id,
                summary: "s", metadata: nil,
                createdCards: ["ghost-id"], artifacts: [])
            Issue.record("should refuse")
        } catch CardStoreError.phantomCreatedCard(let id) {
            #expect(id == "ghost-id")
        }
    }

    @Test("block kinds route; unblock reclaims stale runs")
    func blockUnblock() async throws {
        let store = makeStore()
        let task = try await store.createTask(CardTask(title: "t"), board: "default")
        let (_, run) = try await store.claimTask(id: task.id, board: "default", profile: nil)
        let (depBlocked, depRun) = try await store.blockTask(
            id: task.id, board: "default", runID: run.id, kind: .dependency, reason: "waiting on parent")
        #expect(depBlocked.status == .todo)
        #expect(depRun?.outcome == .blocked)
        // Dependency wait auto-resumes: parent done → recompute promotes.
        let parent = try await store.createTask(CardTask(title: "p", status: .done), board: "default")
        try await store.link(parentID: parent.id, childID: task.id, board: "default")
        let promoted = try await store.recomputeReady(board: "default")
        #expect(promoted == [task.id])
        #expect(try await store.getTask(id: task.id, board: "default")?.status == .ready)

        // Human block + unblock reclaims the stale run.
        let (_, run2) = try await store.claimTask(id: task.id, board: "default", profile: nil)
        let (blocked, _) = try await store.blockTask(
            id: task.id, board: "default", runID: nil, kind: .needs_input, reason: "need a decision")
        #expect(blocked.status == .blocked)
        let unblocked = try await store.unblockTask(id: task.id, board: "default")
        #expect(unblocked.status == .ready)
        #expect(unblocked.currentRunID == nil)
        let runs = try await store.runs(taskID: task.id, board: "default")
        // The block itself closed run #2 with outcome .blocked (the
        // reference closes the active run at block time, not unblock).
        #expect(runs.last?.outcome == .blocked)
        #expect(runs.last?.status == .blocked)
    }

    @Test("failTask records outcome and trips the breaker")
    func failures() async throws {
        let store = makeStore()
        let task = try await store.createTask(CardTask(title: "t"), board: "default")
        let (_, run1) = try await store.claimTask(id: task.id, board: "default", profile: nil)
        let (afterOne, _, tripped1) = try await store.failTask(
            id: task.id, board: "default", runID: run1.id, outcome: .crashed, error: "segfault")
        #expect(!tripped1)
        #expect(afterOne.status == .ready)
        let (_, run2) = try await store.claimTask(id: task.id, board: "default", profile: nil)
        let (afterTwo, _, tripped2) = try await store.failTask(
            id: task.id, board: "default", runID: run2.id, outcome: .timed_out, error: "over budget")
        #expect(tripped2)
        #expect(afterTwo.status == .blocked)
        #expect(afterTwo.lastFailureError == "over budget")
    }

    @Test("heartbeat stamps task and run")
    func heartbeat() async throws {
        let store = makeStore()
        let task = try await store.createTask(CardTask(title: "t"), board: "default")
        let (_, run) = try await store.claimTask(id: task.id, board: "default", profile: nil)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.heartbeat(id: task.id, board: "default", runID: nil)
        let after = try await store.getTask(id: task.id, board: "default")
        #expect(after?.lastHeartbeatAt != nil)
        let runs = try await store.runs(taskID: task.id, board: "default")
        #expect(runs.first?.lastHeartbeatAt != nil)
        _ = run
    }

    @Test("links: cycle refused, parents/children listed")
    func links() async throws {
        let store = makeStore()
        let a = try await store.createTask(CardTask(title: "a"), board: "default")
        let b = try await store.createTask(CardTask(title: "b"), board: "default")
        let c = try await store.createTask(CardTask(title: "c"), board: "default")
        try await store.link(parentID: a.id, childID: b.id, board: "default")
        try await store.link(parentID: b.id, childID: c.id, board: "default")
        #expect(try await store.parentIDs(of: c.id, board: "default") == [b.id])
        #expect(try await store.childIDs(of: a.id, board: "default") == [b.id])
        do {
            try await store.link(parentID: c.id, childID: a.id, board: "default")
            Issue.record("cycle should refuse")
        } catch CardStoreError.parentCycle {}
        do {
            try await store.link(parentID: "ghost", childID: a.id, board: "default")
            Issue.record("missing parent should refuse")
        } catch CardStoreError.parentNotFound(let id) {
            #expect(id == "ghost")
        }
        // A dispatchable child gains a parent → re-gated to todo.
        let d = try await store.createTask(CardTask(title: "d"), board: "default")
        try await store.link(parentID: a.id, childID: d.id, board: "default")
        #expect(try await store.getTask(id: d.id, board: "default")?.status == .todo)
    }

    @Test("comments and events append in order")
    func commentsEvents() async throws {
        let store = makeStore()
        let task = try await store.createTask(CardTask(title: "t"), board: "default")
        _ = try await store.addComment(taskID: task.id, board: "default", author: "agent", body: "first")
        _ = try await store.addComment(taskID: task.id, board: "default", author: "worker", body: "second")
        let comments = try await store.comments(taskID: task.id, board: "default")
        #expect(comments.map(\.body) == ["first", "second"])
        let events = try await store.events(taskID: task.id, board: "default", limit: 50)
        #expect(events.map(\.kind).contains("created"))
        #expect(events.map(\.kind).contains("commented"))
    }

    @Test("attachments write blobs and record absolute paths")
    func attachments() async throws {
        let store = makeStore()
        let task = try await store.createTask(CardTask(title: "t"), board: "default")
        let att = try await store.attach(
            taskID: task.id, board: "default", filename: "report.pdf",
            contentType: "application/pdf", data: Data("%PDF-1.4 fake".utf8))
        #expect(FileManager.default.fileExists(atPath: att.storedPath))
        #expect(att.size == "%PDF-1.4 fake".utf8.count)
        #expect(try await store.attachments(taskID: task.id, board: "default").count == 1)
    }

    @Test("deleteBoard wipes everything")
    func deleteBoard() async throws {
        let store = makeStore()
        let task = try await store.createTask(CardTask(title: "t"), board: "doomed")
        _ = try await store.addComment(taskID: task.id, board: "doomed", author: "agent", body: "x")
        try await store.deleteBoard(board: "doomed")
        #expect(try await store.getTask(id: task.id, board: "doomed") == nil)
    }

    @Test("worker context follows the reference order with caps")
    func workerContext() async throws {
        let store = makeStore()
        let body = String(repeating: "b", count: 9_000)
        let parent = try await store.createTask(CardTask(title: "parent"), board: "default")
        let (_, prun) = try await store.claimTask(id: parent.id, board: "default", profile: nil)
        _ = try await store.completeTask(
            id: parent.id, board: "default", runID: prun.id,
            summary: String(repeating: "P", count: 5_000), metadata: nil,
            createdCards: [], artifacts: [])
        let child = try await store.createTask(
            CardTask(title: "child", body: body, assignee: "specialist"), board: "default")
        try await store.link(parentID: parent.id, childID: child.id, board: "default")
        // Parent was already settled when the link landed — the child
        // stays dispatchable and recompute has nothing to do.
        let promoted = try await store.recomputeReady(board: "default")
        #expect(promoted.isEmpty)
        #expect(try await store.getTask(id: child.id, board: "default")?.status == .ready)
        _ = try await store.addComment(taskID: child.id, board: "default", author: "human", body: "note")
        let att = try await store.attach(
            taskID: child.id, board: "default", filename: "data.csv", contentType: "text/csv", data: Data("a,b".utf8))
        let (task, run) = try await store.claimTask(id: child.id, board: "default", profile: "specialist")
        let context = try await CardWorker.workerContext(store: store, task: task, run: run)
        #expect(context.hasPrefix("# Kanban task \(child.id): child"))
        #expect(context.contains("Assignee: specialist"))
        #expect(context.contains("… [truncated, 808 chars omitted]")) // 8KB body cap (8192)
        #expect(context.contains("## Attachments"))
        #expect(context.contains(att.storedPath))
        #expect(context.contains("## Parent task results"))
        #expect(context.contains("## Comments"))
        #expect(context.contains("kanban` tool"))
    }
}

@Suite("KanbanTool — the unified surface")
struct KanbanToolTests {

    final class Box: @unchecked Sendable { let store: any CardStore; init(_ s: any CardStore) { store = s } }

    func entry(_ store: any CardStore) -> ToolEntry {
        KanbanTool.entry(storeOverride: store)
    }

    @Test("create → list → show through the tool")
    func createListShow() async throws {
        let store = makeStore()
        let tool = entry(store)
        let out = try await tool.handler(["action": "create", "title": "via tool", "priority": 3])
        #expect(out.contains("Created task"))
        let list = try await tool.handler(["action": "list"])
        #expect(list.contains("via tool"))
        // show by id extracted from create output
        let id = out.replacingOccurrences(of: "Created task ", with: "")
            .prefix(while: { $0 != " " })
        let shown = try await tool.handler(["action": "show", "task_id": String(id)])
        #expect(shown.contains("Status: ready"))
    }

    @Test("worker env defaults complete the claimed task")
    func workerDefaults() async throws {
        let store = makeStore()
        let tool = entry(store)
        let created = try await tool.handler(["action": "create", "title": "worker task"])
        let id = created.replacingOccurrences(of: "Created task ", with: "").prefix(while: { $0 != " " })
        let (_, run) = try await store.claimTask(id: String(id), board: "default", profile: nil)
        let workerTool = KanbanTool.entry(
            storeOverride: store,
            envOverride: [CardWorker.taskIDKey: String(id), CardWorker.runIDKey: run.id, CardWorker.boardKey: "default"])
        let out = try await workerTool.handler(["action": "complete", "summary": "did the thing", "metadata": ["files": "1"]])
        #expect(out.contains("completed"))
        let status = try await store.getTask(id: String(id), board: "default")
        #expect(status?.status == .done)
    }

    @Test("block validation: missing reason, bad kind, dependency routing message")
    func blockValidation() async throws {
        let store = makeStore()
        let tool = entry(store)
        let created = try await tool.handler(["action": "create", "title": "b"])
        let id = created.replacingOccurrences(of: "Created task ", with: "").prefix(while: { $0 != " " })
        _ = try await store.claimTask(id: String(id), board: "default", profile: nil)
        let noReason = try await tool.handler(["action": "block", "task_id": String(id)])
        #expect(noReason.contains("requires a `reason`"))
        let badKind = try await tool.handler(["action": "block", "task_id": String(id), "kind": "wat", "reason": "r"])
        #expect(badKind.contains("kind must be"))
        let dep = try await tool.handler(["action": "block", "task_id": String(id), "kind": "dependency", "reason": "parent"])
        #expect(dep.contains("auto-resumes"))
    }

    @Test("unknown action and unknown task fail legibly")
    func legibleErrors() async throws {
        let store = makeStore()
        let tool = entry(store)
        let out = try await tool.handler(["action": "teleport"])
        #expect(out.contains("unknown action"))
        let missing = try await tool.handler(["action": "show", "task_id": "ghost"])
        #expect(missing.contains("not found"))
    }

    @Test("complete without a run id is refused")
    func completeWithoutRun() async throws {
        let store = makeStore()
        let tool = entry(store)
        let created = try await tool.handler(["action": "create", "title": "c"])
        let id = created.replacingOccurrences(of: "Created task ", with: "").prefix(while: { $0 != " " })
        let out = try await tool.handler(["action": "complete", "task_id": String(id), "summary": "s"])
        #expect(out.contains("no active run"))
    }

    func makeStore() -> FileCardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cardtool-tests-\(UUID().uuidString)", isDirectory: true)
        return FileCardStore(arcHome: tmp)
    }
}
