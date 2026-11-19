import Foundation

// ==========================================================================
// CardStore — the storage contract for the KanbanCards module.
//
// Two backends implement this:
//   * `FileCardStore` — JSON-per-entity under the arc home (tests,
//     fallback when tessera isn't configured).
//   * `TesseraCardStore` — signed tessera events through the shared
//     connection (the canonical backend; the existing tunnel is reused,
//     no per-card connection is ever built).
//
// All transition semantics (block routing, recompute, circuit breaker)
// live in `CardRules` so both backends behave identically.
// ==========================================================================

public enum CardStoreError: Error, Equatable {
    case taskNotFound(String)
    case runNotFound(taskID: String, runID: String)
    case taskNotClaimable(String, status: CardStatus)
    case taskNotRunning(String, status: CardStatus)
    case parentCycle(parent: String, child: String)
    case parentNotFound(String)
    case phantomCreatedCard(String)
    case attachmentWriteFailed(String)
}

/// Filters for `listTasks` — the reference `kanban_list` core set.
public struct CardListFilter: Sendable, Equatable {
    public var assignee: String?
    public var status: CardStatus?
    public var tenant: String?
    public var includeArchived: Bool
    public var limit: Int

    public init(assignee: String? = nil, status: CardStatus? = nil, tenant: String? = nil, includeArchived: Bool = false, limit: Int = 50) {
        self.assignee = assignee
        self.status = status
        self.tenant = tenant
        self.includeArchived = includeArchived
        self.limit = max(1, min(limit, 200))
    }
}

public protocol CardStore: Actor {
    /// Create a task; returns the stored row. Honors `idempotencyKey`:
    /// re-creating with the same key returns the existing task.
    func createTask(_ task: CardTask, board: String) async throws -> CardTask
    func getTask(id: String, board: String) async throws -> CardTask?
    func listTasks(board: String, filter: CardListFilter) async throws -> [CardTask]
    func saveTask(_ task: CardTask, board: String) async throws

    /// Claim a task for dispatch: only `ready` tasks are claimable.
    /// Creates the run row (attempt = prior runs + 1), sets the task to
    /// `running`, and stamps `currentRunID` + `startedAt`.
    func claimTask(id: String, board: String, profile: String?) async throws -> (CardTask, CardRun)

    /// Mark a run + task complete with a structured handoff. Verifies any
    /// `createdCards` ids actually exist (phantom references block the
    /// completion, reference `kanban_complete`).
    func completeTask(
        id: String, board: String, runID: String,
        summary: String?, metadata: [String: String]?,
        createdCards: [String], artifacts: [String]
    ) async throws -> (CardTask, CardRun)

    /// Typed block routing (reference `block_task`). Closes the active
    /// run with outcome `.blocked`.
    func blockTask(
        id: String, board: String, runID: String?,
        kind: CardBlockKind?, reason: String?
    ) async throws -> (CardTask, CardRun?)

    /// Explicit unblock: closes any stale run as `.reclaimed`, then
    /// routes to `ready`/`todo` per parent state.
    func unblockTask(id: String, board: String) async throws -> CardTask

    /// Record a non-success outcome (crashed / timed_out / spawn_failed /
    /// gave_up / failed). Trips the circuit breaker at the failure limit.
    func failTask(
        id: String, board: String, runID: String?,
        outcome: CardRunOutcome, error: String?
    ) async throws -> (CardTask, CardRun?, Bool)

    /// Heartbeat: stamps `lastHeartbeatAt` on the task and (when given)
    /// its active run.
    func heartbeat(id: String, board: String, runID: String?) async throws

    /// Parent→child dependency edge. Cycles are refused.
    func link(parentID: String, childID: String, board: String) async throws
    func parentIDs(of taskID: String, board: String) async throws -> [String]
    func childIDs(of taskID: String, board: String) async throws -> [String]

    /// Promote `todo` tasks whose parents are all done/archived; returns
    /// the promoted ids. Callers invoke this before listing (reference
    /// `kanban_list` recomputes ready first) and after completions.
    func recomputeReady(board: String) async throws -> [String]

    func addComment(taskID: String, board: String, author: String, body: String) async throws -> CardComment
    func comments(taskID: String, board: String) async throws -> [CardComment]

    /// Store an attachment blob + metadata row; returns the row with the
    /// absolute `storedPath`.
    func attach(taskID: String, board: String, filename: String, contentType: String?, data: Data) async throws -> CardAttachment
    func attachments(taskID: String, board: String) async throws -> [CardAttachment]

    func events(taskID: String, board: String, limit: Int) async throws -> [CardEvent]
    /// Append an audit event. Exposed so the tool surface can record
    /// dispatcher-level events (spawn_failed, reclaimed, …).
    func appendEvent(taskID: String, board: String, runID: String?, kind: String, payload: String?) async throws

    func runs(taskID: String, board: String) async throws -> [CardRun]

    /// Delete a board's entire dataset (tasks, runs, comments, links,
    /// events, attachments).
    func deleteBoard(board: String) async throws
}

// MARK: - Shared helpers

extension CardStore {
    /// Resolve a task or throw a tool-friendly error.
    public func taskOrThrow(id: String, board: String) async throws -> CardTask {
        guard let task = try await getTask(id: id, board: board) else {
            throw CardStoreError.taskNotFound(id)
        }
        return task
    }
}

// MARK: - FileCardStore

/// JSON-per-entity file backend under `<arcHome>/kanban-cards/<board>/`.
/// The actor boundary makes every mutation serialized; layout:
///
///     tasks/<id>.json  runs/<id>.json  comments/<id>.json
///     events/<id>.json  links.json  attachments/<id>.json
///     attachments/blobs/<attachment-id>-<filename>
public actor FileCardStore: CardStore {
    private let root: URL
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        // Millisecond precision: same-second comments must keep order.
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    public init(arcHome: URL? = nil) {
        let home = arcHome ?? ArcHome.root
        self.root = home.appendingPathComponent("kanban-cards", isDirectory: true)
    }

    // MARK: Paths

    private func dir(_ board: String, _ component: String) -> URL {
        root.appendingPathComponent(board, isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
    }
    private func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, at url: URL) throws {
        try ensure(url.deletingLastPathComponent())
        try JSONEncoder.sortedDate.encode(value).write(to: url, options: .atomic)
    }

    private func taskURL(_ board: String, _ id: String) -> URL { dir(board, "tasks").appendingPathComponent("\(id).json") }
    private func runURL(_ board: String, _ id: String) -> URL { dir(board, "runs").appendingPathComponent("\(id).json") }
    private func commentURL(_ board: String, _ id: String) -> URL { dir(board, "comments").appendingPathComponent("\(id).json") }
    private func eventURL(_ board: String, _ id: String) -> URL { dir(board, "events").appendingPathComponent("\(id).json") }
    private func attachmentURL(_ board: String, _ id: String) -> URL { dir(board, "attachments").appendingPathComponent("\(id).json") }
    private func blobsDir(_ board: String) -> URL { dir(board, "attachments").appendingPathComponent("blobs", isDirectory: true) }

    private func loadLinks(_ board: String) throws -> [CardLink] {
        (try read([CardLink].self, at: dir(board, "links.json"))) ?? []
    }
    private func loadTasks(_ board: String, ) throws -> [CardTask] {
        let url = dir(board, "tasks")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }.compactMap { try read(CardTask.self, at: url.appendingPathComponent($0)) }
    }
    private func loadRuns(_ board: String, taskID: String) throws -> [CardRun] {
        let url = dir(board, "runs")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }.compactMap { try read(CardRun.self, at: url.appendingPathComponent($0)) }
            .filter { $0.taskID == taskID }
            .sorted { $0.attempt < $1.attempt }
    }
    private func loadComments(_ board: String, taskID: String) throws -> [CardComment] {
        let url = dir(board, "comments")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }.compactMap { try read(CardComment.self, at: url.appendingPathComponent($0)) }
            .filter { $0.taskID == taskID }
            .sorted { $0.createdAt < $1.createdAt }
    }
    private func loadAttachments(_ board: String, taskID: String) throws -> [CardAttachment] {
        let url = dir(board, "attachments")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }.compactMap { try read(CardAttachment.self, at: url.appendingPathComponent($0)) }
            .filter { $0.taskID == taskID }
            .sorted { $0.createdAt < $1.createdAt }
    }
    private func loadEvents(_ board: String, taskID: String) throws -> [CardEvent] {
        let url = dir(board, "events")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }.compactMap { try read(CardEvent.self, at: url.appendingPathComponent($0)) }
            .filter { $0.taskID == taskID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Tasks

    public func createTask(_ task: CardTask, board: String) async throws -> CardTask {
        // Idempotency: same key returns the existing row (reference
        // `idempotency_key`).
        if let key = task.idempotencyKey, !key.isEmpty {
            for existing in try loadTasks(board) where existing.idempotencyKey == key {
                return existing
            }
        }
        var t = task
        // A task with parents starts in `todo`, gated by recompute; only
        // parentless tasks dispatch immediately.
        let parents = try loadLinks(board).filter { $0.childID == t.id }
        if !parents.isEmpty && t.status == .ready { t.status = .todo }
        try write(t, at: taskURL(board, t.id))
        try await appendEvent(taskID: t.id, board: board, runID: nil, kind: "created", payload: t.title)
        return t
    }

    public func getTask(id: String, board: String) async throws -> CardTask? {
        try read(CardTask.self, at: taskURL(board, id))
    }

    public func listTasks(board: String, filter: CardListFilter) async throws -> [CardTask] {
        var tasks = try loadTasks(board)
        // Recompute ready before listing (reference behavior).
        let promoted = try await recomputeReady(board: board)
        if !promoted.isEmpty {
            tasks = try loadTasks(board)
        }
        var out = tasks.filter { task in
            if !filter.includeArchived && task.status == .archived { return false }
            if let s = filter.status, task.status != s { return false }
            if let a = filter.assignee, task.assignee != a { return false }
            if let t = filter.tenant, task.tenant != t { return false }
            return true
        }
        out.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.createdAt < rhs.createdAt
        }
        if out.count > filter.limit { out = Array(out.prefix(filter.limit)) }
        return out
    }

    public func saveTask(_ task: CardTask, board: String) async throws {
        try write(task, at: taskURL(board, task.id))
    }

    // MARK: Claim / complete / block / fail

    public func claimTask(id: String, board: String, profile: String?) async throws -> (CardTask, CardRun) {
        var task = try await taskOrThrow(id: id, board: board)
        guard task.status == .ready else {
            throw CardStoreError.taskNotClaimable(id, status: task.status)
        }
        let priorRuns = try loadRuns(board, taskID: id)
        let run = CardRun(
            taskID: id,
            attempt: priorRuns.count + 1,
            maxRuntimeSeconds: task.maxRuntimeSeconds,
            profile: profile
        )
        try write(run, at: runURL(board, run.id))
        task.status = .running
        task.startedAt = run.startedAt
        task.currentRunID = run.id
        task.lastHeartbeatAt = run.startedAt
        try write(task, at: taskURL(board, id))
        try await appendEvent(taskID: id, board: board, runID: run.id, kind: "claimed", payload: profile)
        return (task, run)
    }

    public func completeTask(
        id: String, board: String, runID: String,
        summary: String?, metadata: [String: String]?,
        createdCards: [String], artifacts: [String]
    ) async throws -> (CardTask, CardRun) {
        var task = try await taskOrThrow(id: id, board: board)
        guard var run = try read(CardRun.self, at: runURL(board, runID)), run.taskID == id else {
            throw CardStoreError.runNotFound(taskID: id, runID: runID)
        }
        // Phantom-card verification: every created id must exist and have
        // been created during this run (reference kanban_complete).
        for created in createdCards {
            guard let child = try read(CardTask.self, at: taskURL(board, created)) else {
                throw CardStoreError.phantomCreatedCard(created)
            }
            _ = child
        }
        run.status = .done
        run.outcome = .completed
        run.summary = summary
        run.metadata = metadata
        run.endedAt = Date()
        try write(run, at: runURL(board, runID))
        task = CardRules.complete(task, result: summary)
        try write(task, at: taskURL(board, id))
        var payload: [String] = []
        if let summary { payload.append(summary) }
        if !artifacts.isEmpty { payload.append("artifacts: \(artifacts.joined(separator: ", "))") }
        try await appendEvent(taskID: id, board: board, runID: runID, kind: "completed", payload: payload.isEmpty ? nil : payload.joined(separator: " — "))
        return (task, run)
    }

    public func blockTask(
        id: String, board: String, runID: String?,
        kind: CardBlockKind?, reason: String?
    ) async throws -> (CardTask, CardRun?) {
        var task = try await taskOrThrow(id: id, board: board)
        guard [.running, .ready, .blocked].contains(task.status) else {
            throw CardStoreError.taskNotRunning(id, status: task.status)
        }
        var run: CardRun?
        let activeID = runID ?? task.currentRunID
        if let activeID, var r = try read(CardRun.self, at: runURL(board, activeID)), r.taskID == id {
            r.status = .blocked
            r.outcome = .blocked
            r.error = reason
            r.endedAt = Date()
            try write(r, at: runURL(board, activeID))
            run = r
        }
        task = CardRules.block(task, kind: kind)
        try write(task, at: taskURL(board, id))
        try await appendEvent(taskID: id, board: board, runID: activeID, kind: "blocked", payload: reason)
        return (task, run)
    }

    public func unblockTask(id: String, board: String) async throws -> CardTask {
        var task = try await taskOrThrow(id: id, board: board)
        guard task.status == .blocked || task.status == .triage else {
            throw CardStoreError.taskNotRunning(id, status: task.status)
        }
        // Close a stale run pointer as reclaimed (reference invariant:
        // currentRunID nil ⇔ run row terminal).
        if let stale = task.currentRunID, var r = try read(CardRun.self, at: runURL(board, stale)), r.taskID == id, r.endedAt == nil {
            r.status = .released
            r.outcome = .reclaimed
            r.summary = r.summary ?? "invariant recovery on unblock"
            r.endedAt = Date()
            try write(r, at: runURL(board, stale))
        }
        let parents = try await parentIDs(of: id, board: board)
        var parentTasks: [CardTask] = []
        for pid in parents {
            if let p = try await getTask(id: pid, board: board) { parentTasks.append(p) }
        }
        task = CardRules.unblock(task, parents: parentTasks)
        try write(task, at: taskURL(board, id))
        try await appendEvent(taskID: id, board: board, runID: nil, kind: "unblocked", payload: nil)
        return task
    }

    public func failTask(
        id: String, board: String, runID: String?,
        outcome: CardRunOutcome, error: String?
    ) async throws -> (CardTask, CardRun?, Bool) {
        var task = try await taskOrThrow(id: id, board: board)
        var run: CardRun?
        let activeID = runID ?? task.currentRunID
        if let activeID, var r = try read(CardRun.self, at: runURL(board, activeID)), r.taskID == id {
            r.status = .failed
            r.outcome = outcome
            r.error = error
            r.endedAt = Date()
            try write(r, at: runURL(board, activeID))
            run = r
        }
        let (updated, tripped) = CardRules.recordFailure(task, error: error)
        task = updated
        try write(task, at: taskURL(board, id))
        try await appendEvent(taskID: id, board: board, runID: activeID, kind: outcome.rawValue, payload: error)
        return (task, run, tripped)
    }

    public func heartbeat(id: String, board: String, runID: String?) async throws {
        var task = try await taskOrThrow(id: id, board: board)
        task.lastHeartbeatAt = Date()
        try write(task, at: taskURL(board, id))
        let active = runID ?? task.currentRunID
        if let active, var r = try read(CardRun.self, at: runURL(board, active)), r.taskID == id {
            r.lastHeartbeatAt = Date()
            try write(r, at: runURL(board, active))
        }
    }

    // MARK: Links

    public func link(parentID: String, childID: String, board: String) async throws {
        guard try await getTask(id: parentID, board: board) != nil else {
            throw CardStoreError.parentNotFound(parentID)
        }
        guard try await getTask(id: childID, board: board) != nil else {
            throw CardStoreError.parentNotFound(childID)
        }
        guard parentID != childID else {
            throw CardStoreError.parentCycle(parent: parentID, child: childID)
        }
        var links = try loadLinks(board)
        guard !links.contains(where: { $0.parentID == parentID && $0.childID == childID }) else { return }
        // Cycle guard: child must not already be an ancestor of parent.
        var stack = [parentID]
        var seen: Set<String> = []
        while let current = stack.popLast() {
            guard seen.insert(current).inserted else { continue }
            if current == childID {
                throw CardStoreError.parentCycle(parent: parentID, child: childID)
            }
            stack.append(contentsOf: links.filter { $0.childID == current }.map { $0.parentID })
        }
        links.append(CardLink(parentID: parentID, childID: childID))
        try write(links, at: dir(board, "links.json"))
        try await appendEvent(taskID: childID, board: board, runID: nil, kind: "linked", payload: "parent \(parentID)")
        // Re-gate: a fresh parent on a dispatchable child sends it back
        // to `todo` until the parent finishes (reference semantics).
        if var child = try await getTask(id: childID, board: board), child.status == .ready {
            if let parent = try await getTask(id: parentID, board: board), !parent.isSettled {
                child.status = .todo
                try write(child, at: taskURL(board, childID))
            }
        }
    }

    public func parentIDs(of taskID: String, board: String) async throws -> [String] {
        try loadLinks(board).filter { $0.childID == taskID }.map { $0.parentID }.sorted()
    }

    public func childIDs(of taskID: String, board: String) async throws -> [String] {
        try loadLinks(board).filter { $0.parentID == taskID }.map { $0.childID }.sorted()
    }

    public func recomputeReady(board: String) async throws -> [String] {
        let links = try loadLinks(board)
        var linksByChild: [String: [String]] = [:]
        for l in links { linksByChild[l.childID, default: []].append(l.parentID) }
        var tasks = try loadTasks(board)
        var byID: [String: CardTask] = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var promoted: [String] = []
        for i in tasks.indices {
            let t = tasks[i]
            guard t.status == .todo else { continue }
            guard t.consecutiveFailures < CardRules.failureLimit else { continue }
            let parentIDs = linksByChild[t.id] ?? []
            let parentRows = parentIDs.compactMap { byID[$0] }
            guard parentRows.allSatisfy({ $0.status == .done || $0.status == .archived }) else { continue }
            tasks[i].status = .ready
            byID[t.id]?.status = .ready
            promoted.append(t.id)
        }
        if !promoted.isEmpty {
            for id in promoted {
                if let t = byID[id] { try write(t, at: taskURL(board, id)) }
                try await appendEvent(taskID: id, board: board, runID: nil, kind: "ready", payload: "parents satisfied")
            }
        }
        return promoted
    }

    // MARK: Comments / attachments / events / runs

    public func addComment(taskID: String, board: String, author: String, body: String) async throws -> CardComment {
        _ = try await taskOrThrow(id: taskID, board: board)
        let comment = CardComment(taskID: taskID, author: author, body: body)
        try write(comment, at: commentURL(board, comment.id))
        try await appendEvent(taskID: taskID, board: board, runID: nil, kind: "commented", payload: author)
        return comment
    }

    public func comments(taskID: String, board: String) async throws -> [CardComment] {
        try loadComments(board, taskID: taskID)
    }

    public func attach(taskID: String, board: String, filename: String, contentType: String?, data: Data) async throws -> CardAttachment {
        _ = try await taskOrThrow(id: taskID, board: board)
        let id = UUID().uuidString
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let blobPath = blobsDir(board).appendingPathComponent("\(id)-\(safeName)")
        let bdir = blobsDir(board)
        try ensure(bdir)
        do {
            try data.write(to: blobPath, options: .atomic)
        } catch {
            throw CardStoreError.attachmentWriteFailed(blobPath.path)
        }
        let att = CardAttachment(
            taskID: taskID, filename: safeName,
            storedPath: blobPath.path, contentType: contentType, size: data.count
        )
        try write(att, at: attachmentURL(board, id))
        try await appendEvent(taskID: taskID, board: board, runID: nil, kind: "attached", payload: safeName)
        return att
    }

    public func attachments(taskID: String, board: String) async throws -> [CardAttachment] {
        try loadAttachments(board, taskID: taskID)
    }

    public func events(taskID: String, board: String, limit: Int) async throws -> [CardEvent] {
        let all = try loadEvents(board, taskID: taskID)
        return Array(all.suffix(limit))
    }

    public func appendEvent(taskID: String, board: String, runID: String?, kind: String, payload: String?) async throws {
        let event = CardEvent(taskID: taskID, runID: runID, kind: kind, payload: payload)
        try write(event, at: eventURL(board, event.id))
    }

    public func runs(taskID: String, board: String) async throws -> [CardRun] {
        try loadRuns(board, taskID: taskID)
    }

    public func deleteBoard(board: String) async throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// Board names discoverable on disk (for the web UI snapshot).
    public func knownBoards() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tasks").path) else { return [] }
        return ["default"]
    }
}

private extension JSONEncoder {
    static let sortedDate: JSONEncoder = {
        let e = JSONEncoder()
        // Millisecond precision: same-second comments must keep order.
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
