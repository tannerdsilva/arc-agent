import Foundation
import Logging

// ==========================================================================
// TesseraCardStore — the canonical KanbanCards backend.
//
// Every entity is a signed tessera event posted through the SHARED
// connection (`TesseraConnection.shared`). No card ever builds its own
// tunnel: the worker process assumes a consistent connection and just
// publishes, exactly like every other arc surface.
//
// Kinds (arc's <40,000 application range; 3011-3013 are the legacy
// KanbanAgent engine):
//
//   3014 card task       dTag: arc/cards/<board>/task/<taskID>/<seq>
//   3015 card run        dTag: arc/cards/<board>/run/<runID>/<seq>
//   3016 card comment    dTag: arc/cards/<board>/comment/<commentID>/<seq>
//   3017 card link       dTag: arc/cards/<board>/link/<parentID>→<childID>/<seq>
//   3018 card event      dTag: arc/cards/<board>/event/<eventID>/<seq>
//   3019 card attachment dTag: arc/cards/<board>/attachment/<attID>/<seq>
//
// Replaceable rows (task, run) use latest-seq-wins; appends (comment,
// event, link, attachment) are immutable rows. Attachments store only
// metadata here — blobs go to the store's on-disk attachments root.
// ==========================================================================

public actor TesseraCardStore: CardStore {
    public static let taskKind: UInt32 = 3_014
    public static let runKind: UInt32 = 3_015
    public static let commentKind: UInt32 = 3_016
    public static let linkKind: UInt32 = 3_017
    public static let eventKind: UInt32 = 3_018
    public static let attachmentKind: UInt32 = 3_019
    public static let boardKind: UInt32 = 3_020

    /// Blobs live under the arc home so workers can read them by absolute
    /// path (reference `task_attachments.stored_path`).
    public static func blobsRoot(arcHome: URL? = nil) -> URL {
        (arcHome ?? ArcHome.root).appendingPathComponent("kanban-cards/attachments/blobs", isDirectory: true)
    }

    private let connection: TesseraConnection
    private let arcHome: URL
    // Per-board freshness: a single global `loaded` flag made the second
    // board on any shared instance read a nil per-board cache (the
    // ensureLoaded early-return fired for a board that had never loaded).
    private var loadedBoards: Set<String> = []
    private var lastSyncByBoard: [String: Date] = [:]

    // In-memory caches keyed by board.
    private var tasks: [String: [String: CardTask]] = [:]
    private var runs: [String: [String: CardRun]] = [:]
    private var comments: [String: [String: CardComment]] = [:]
    private var links: [String: [CardLink]] = [:]
    private var events: [String: [CardEvent]] = [:]
    private var attachments: [String: [String: CardAttachment]] = [:]

    public init(connection: TesseraConnection = .shared, arcHome: URL? = nil) {
        self.connection = connection
        self.arcHome = arcHome ?? ArcHome.root
    }

    // MARK: Snapshot decode

    private static func latest<T: Codable & Identifiable>(_ type: T.Type, from records: [TesseraRecord], prefix: String, board: String) -> [String: T] {
        var latest: [String: (seq: Int, value: T)] = [:]
        let head = "arc/cards/\(board)/"
        for record in records {
            guard let dTag = record.dTag, dTag.hasPrefix("\(head)\(prefix)/"),
                  let seq = TesseraConnection.sequenceNumber(fromTagKey: dTag)
            else { continue }
            // dTag: <head><prefix>/<entityID>/<seq> — entityID is between.
            let rest = dTag.dropFirst(head.count + prefix.count + 1)
            let entityID = String(rest.prefix(while: { $0 != "/" }))
            guard let data = record.content.data(using: .utf8),
                  let value = try? JSONDecoder.isoDate.decode(T.self, from: data)
            else { continue }
            if seq > (latest[entityID]?.seq ?? -1) {
                latest[entityID] = (seq, value)
            }
        }
        return latest.mapValues { $0.value }
    }

    private func ensureLoaded(board: String) async throws {
        if loadedBoards.contains(board), let last = lastSyncByBoard[board],
           Date().timeIntervalSince(last) < 2 { return }
        try await connection.ensureStarted()
        let head = "arc/cards/\(board)/"
        tasks[board] = Self.latest(CardTask.self, from: await connection.snapshot(kind: Self.taskKind), prefix: "task", board: board)
        runs[board] = Self.latest(CardRun.self, from: await connection.snapshot(kind: Self.runKind), prefix: "run", board: board)
        comments[board] = Self.latest(CardComment.self, from: await connection.snapshot(kind: Self.commentKind), prefix: "comment", board: board)
        attachments[board] = Self.latest(CardAttachment.self, from: await connection.snapshot(kind: Self.attachmentKind), prefix: "attachment", board: board)

        // Links & events are append-only rows.
        var linkRows: [CardLink] = []
        var seenLinks: Set<String> = []
        for record in await connection.snapshot(kind: Self.linkKind) {
            guard let dTag = record.dTag, dTag.hasPrefix(head), dTag.contains("/link/") else { continue }
            guard let data = record.content.data(using: .utf8),
                  let link = try? JSONDecoder.isoDate.decode(CardLink.self, from: data)
            else { continue }
            if seenLinks.insert("\(link.parentID)→\(link.childID)").inserted { linkRows.append(link) }
        }
        links[board] = linkRows

        var eventRows: [CardEvent] = []
        for record in await connection.snapshot(kind: Self.eventKind) {
            guard let dTag = record.dTag, dTag.hasPrefix(head), dTag.contains("/event/") else { continue }
            guard let data = record.content.data(using: .utf8),
                  let event = try? JSONDecoder.isoDate.decode(CardEvent.self, from: data)
            else { continue }
            eventRows.append(event)
        }
        events[board] = eventRows.sorted { $0.createdAt < $1.createdAt }

        lastSyncByBoard[board] = Date()
        loadedBoards.insert(board)
    }

    /// Publish one record and await the relay echo. Correctness-critical,
    /// low-frequency writes — the same rule every arc store follows.
    private func publish(kind: UInt32, dTag: String, payload: Data) async throws {
        try await connection.ensureStarted()
        _ = try await connection.publishAwaitingEcho(kind: kind, dTagValue: dTag, content: String(decoding: payload, as: UTF8.self))
    }

    private func dTagHead(_ board: String) -> String { "arc/cards/\(board)" }

    // MARK: Tasks

    public func createTask(_ task: CardTask, board: String) async throws -> CardTask {
        try await ensureLoaded(board: board)
        if let key = task.idempotencyKey, !key.isEmpty {
            for existing in (tasks[board]?.values ?? [:].values) where existing.idempotencyKey == key {
                return existing
            }
        }
        var t = task
        let hasParents = (links[board] ?? []).contains { $0.childID == t.id }
        if hasParents && t.status == .ready { t.status = .todo }
        let seq = await connection.takeSequence()
        try await publish(kind: Self.taskKind, dTag: "\(dTagHead(board))/task/\(t.id)/\(seq)", payload: JSONEncoder.isoDate.encode(t))
        tasks[board, default: [:]][t.id] = t
        try await appendEvent(taskID: t.id, board: board, runID: nil, kind: "created", payload: t.title)
        return t
    }

    public func getTask(id: String, board: String) async throws -> CardTask? {
        try await ensureLoaded(board: board)
        return tasks[board]?[id]
    }

    public func listTasks(board: String, filter: CardListFilter) async throws -> [CardTask] {
        try await ensureLoaded(board: board)
        let promoted = try await recomputeReady(board: board)
        if !promoted.isEmpty {
            try await ensureLoaded(board: board)
        }
        var out = (tasks[board]?.values ?? Dictionary<String, CardTask>().values).filter { task in
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
        try await ensureLoaded(board: board)
        let seq = await connection.takeSequence()
        try await publish(kind: Self.taskKind, dTag: "\(dTagHead(board))/task/\(task.id)/\(seq)", payload: JSONEncoder.isoDate.encode(task))
        tasks[board, default: [:]][task.id] = task
    }

    // MARK: Claim / complete / block / fail

    public func claimTask(id: String, board: String, profile: String?) async throws -> (CardTask, CardRun) {
        try await ensureLoaded(board: board)
        guard var task = tasks[board]?[id] else { throw CardStoreError.taskNotFound(id) }
        guard task.status == .ready else {
            throw CardStoreError.taskNotClaimable(id, status: task.status)
        }
        let priorRuns = (runs[board]?.values ?? Dictionary<String, CardRun>().values).filter { $0.taskID == id }
        let run = CardRun(
            taskID: id,
            attempt: priorRuns.map { $0.attempt }.max().flatMap { $0 + 1 } ?? 1,
            maxRuntimeSeconds: task.maxRuntimeSeconds,
            profile: profile
        )
        let seq = await connection.takeSequence()
        try await publish(kind: Self.runKind, dTag: "\(dTagHead(board))/run/\(run.id)/\(seq)", payload: JSONEncoder.isoDate.encode(run))
        runs[board, default: [:]][run.id] = run
        task.status = .running
        task.startedAt = run.startedAt
        task.currentRunID = run.id
        task.lastHeartbeatAt = run.startedAt
        try await saveTask(task, board: board)
        try await appendEvent(taskID: id, board: board, runID: run.id, kind: "claimed", payload: profile)
        return (task, run)
    }

    public func completeTask(
        id: String, board: String, runID: String,
        summary: String?, metadata: [String: String]?,
        createdCards: [String], artifacts: [String]
    ) async throws -> (CardTask, CardRun) {
        try await ensureLoaded(board: board)
        guard var task = tasks[board]?[id] else { throw CardStoreError.taskNotFound(id) }
        guard var run = runs[board]?[runID], run.taskID == id else {
            throw CardStoreError.runNotFound(taskID: id, runID: runID)
        }
        for created in createdCards {
            guard tasks[board]?[created] != nil else {
                throw CardStoreError.phantomCreatedCard(created)
            }
        }
        run.status = .done
        run.outcome = .completed
        run.summary = summary
        run.metadata = metadata
        run.endedAt = Date()
        let seq = await connection.takeSequence()
        try await publish(kind: Self.runKind, dTag: "\(dTagHead(board))/run/\(runID)/\(seq)", payload: JSONEncoder.isoDate.encode(run))
        runs[board, default: [:]][runID] = run
        task = CardRules.complete(task, result: summary)
        try await saveTask(task, board: board)
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
        try await ensureLoaded(board: board)
        guard var task = tasks[board]?[id] else { throw CardStoreError.taskNotFound(id) }
        guard [.running, .ready, .blocked].contains(task.status) else {
            throw CardStoreError.taskNotRunning(id, status: task.status)
        }
        var run: CardRun?
        let activeID = runID ?? task.currentRunID
        if let activeID, var r = runs[board]?[activeID], r.taskID == id {
            r.status = .blocked
            r.outcome = .blocked
            r.error = reason
            r.endedAt = Date()
            let seq = await connection.takeSequence()
            try await publish(kind: Self.runKind, dTag: "\(dTagHead(board))/run/\(activeID)/\(seq)", payload: JSONEncoder.isoDate.encode(r))
            runs[board, default: [:]][activeID] = r
            run = r
        }
        task = CardRules.block(task, kind: kind)
        try await saveTask(task, board: board)
        try await appendEvent(taskID: id, board: board, runID: activeID, kind: "blocked", payload: reason)
        return (task, run)
    }

    public func unblockTask(id: String, board: String) async throws -> CardTask {
        try await ensureLoaded(board: board)
        guard var task = tasks[board]?[id] else { throw CardStoreError.taskNotFound(id) }
        guard task.status == .blocked || task.status == .triage else {
            throw CardStoreError.taskNotRunning(id, status: task.status)
        }
        if let stale = task.currentRunID, var r = runs[board]?[stale], r.taskID == id, r.endedAt == nil {
            r.status = .released
            r.outcome = .reclaimed
            r.summary = r.summary ?? "invariant recovery on unblock"
            r.endedAt = Date()
            let seq = await connection.takeSequence()
            try await publish(kind: Self.runKind, dTag: "\(dTagHead(board))/run/\(stale)/\(seq)", payload: JSONEncoder.isoDate.encode(r))
            runs[board, default: [:]][stale] = r
        }
        let parentIDs = (links[board] ?? []).filter { $0.childID == id }.map { $0.parentID }.sorted()
        let parentTasks = parentIDs.compactMap { tasks[board]?[$0] }
        task = CardRules.unblock(task, parents: parentTasks)
        try await saveTask(task, board: board)
        try await appendEvent(taskID: id, board: board, runID: nil, kind: "unblocked", payload: nil)
        return task
    }

    public func failTask(
        id: String, board: String, runID: String?,
        outcome: CardRunOutcome, error: String?
    ) async throws -> (CardTask, CardRun?, Bool) {
        try await ensureLoaded(board: board)
        guard var task = tasks[board]?[id] else { throw CardStoreError.taskNotFound(id) }
        var run: CardRun?
        let activeID = runID ?? task.currentRunID
        if let activeID, var r = runs[board]?[activeID], r.taskID == id {
            r.status = .failed
            r.outcome = outcome
            r.error = error
            r.endedAt = Date()
            let seq = await connection.takeSequence()
            try await publish(kind: Self.runKind, dTag: "\(dTagHead(board))/run/\(activeID)/\(seq)", payload: JSONEncoder.isoDate.encode(r))
            runs[board, default: [:]][activeID] = r
            run = r
        }
        let (updated, tripped) = CardRules.recordFailure(task, error: error)
        task = updated
        try await saveTask(task, board: board)
        try await appendEvent(taskID: id, board: board, runID: activeID, kind: outcome.rawValue, payload: error)
        return (task, run, tripped)
    }

    public func heartbeat(id: String, board: String, runID: String?) async throws {
        try await ensureLoaded(board: board)
        guard var task = tasks[board]?[id] else { throw CardStoreError.taskNotFound(id) }
        task.lastHeartbeatAt = Date()
        try await saveTask(task, board: board)
        let active = runID ?? task.currentRunID
        if let active, var r = runs[board]?[active], r.taskID == id {
            r.lastHeartbeatAt = Date()
            let seq = await connection.takeSequence()
            try await publish(kind: Self.runKind, dTag: "\(dTagHead(board))/run/\(active)/\(seq)", payload: JSONEncoder.isoDate.encode(r))
            runs[board, default: [:]][active] = r
        }
    }

    // MARK: Links

    public func link(parentID: String, childID: String, board: String) async throws {
        try await ensureLoaded(board: board)
        guard tasks[board]?[parentID] != nil else { throw CardStoreError.parentNotFound(parentID) }
        guard tasks[board]?[childID] != nil else { throw CardStoreError.parentNotFound(childID) }
        guard parentID != childID else {
            throw CardStoreError.parentCycle(parent: parentID, child: childID)
        }
        let existing = links[board] ?? []
        guard !existing.contains(where: { $0.parentID == parentID && $0.childID == childID }) else { return }
        // Cycle guard: child must not already be an ancestor of parent.
        var stack = [parentID]
        var seen: Set<String> = []
        while let current = stack.popLast() {
            guard seen.insert(current).inserted else { continue }
            if current == childID {
                throw CardStoreError.parentCycle(parent: parentID, child: childID)
            }
            stack.append(contentsOf: existing.filter { $0.childID == current }.map { $0.parentID })
        }
        let link = CardLink(parentID: parentID, childID: childID)
        let seq = await connection.takeSequence()
        try await publish(
            kind: Self.linkKind,
            dTag: "\(dTagHead(board))/link/\(parentID)%E2%86%92\(childID)/\(seq)",
            payload: JSONEncoder.isoDate.encode(link))
        links[board, default: []].append(link)
        try await appendEvent(taskID: childID, board: board, runID: nil, kind: "linked", payload: "parent \(parentID)")
        // Re-gate: a fresh parent on a dispatchable child sends it back
        // to `todo` until the parent finishes (reference semantics).
        if var child = tasks[board]?[childID], child.status == .ready,
           let parent = tasks[board]?[parentID], !parent.isSettled {
            child.status = .todo
            try await saveTask(child, board: board)
        }
    }

    public func parentIDs(of taskID: String, board: String) async throws -> [String] {
        try await ensureLoaded(board: board)
        return (links[board] ?? []).filter { $0.childID == taskID }.map { $0.parentID }.sorted()
    }

    public func childIDs(of taskID: String, board: String) async throws -> [String] {
        try await ensureLoaded(board: board)
        return (links[board] ?? []).filter { $0.parentID == taskID }.map { $0.childID }.sorted()
    }

    public func recomputeReady(board: String) async throws -> [String] {
        try await ensureLoaded(board: board)
        let linkRows = links[board] ?? []
        var linksByChild: [String: [String]] = [:]
        for l in linkRows { linksByChild[l.childID, default: []].append(l.parentID) }
        var byID = tasks[board] ?? [:]
        var promoted: [String] = []
        for id in byID.keys.sorted() {
            guard var t = byID[id], t.status == .todo else { continue }
            guard t.consecutiveFailures < CardRules.failureLimit else { continue }
            let parentRows = (linksByChild[id] ?? []).compactMap { byID[$0] }
            guard parentRows.allSatisfy({ $0.status == .done || $0.status == .archived }) else { continue }
            t.status = .ready
            byID[id] = t
            promoted.append(id)
        }
        if !promoted.isEmpty {
            for id in promoted {
                if let t = byID[id] { try await saveTask(t, board: board) }
                try await appendEvent(taskID: id, board: board, runID: nil, kind: "ready", payload: "parents satisfied")
            }
            tasks[board] = byID
        }
        return promoted
    }

    // MARK: Comments / attachments / events / runs

    public func addComment(taskID: String, board: String, author: String, body: String) async throws -> CardComment {
        try await ensureLoaded(board: board)
        guard tasks[board]?[taskID] != nil else { throw CardStoreError.taskNotFound(taskID) }
        let comment = CardComment(taskID: taskID, author: author, body: body)
        let seq = await connection.takeSequence()
        try await publish(kind: Self.commentKind, dTag: "\(dTagHead(board))/comment/\(comment.id)/\(seq)", payload: JSONEncoder.isoDate.encode(comment))
        comments[board, default: [:]][comment.id] = comment
        try await appendEvent(taskID: taskID, board: board, runID: nil, kind: "commented", payload: author)
        return comment
    }

    public func comments(taskID: String, board: String) async throws -> [CardComment] {
        try await ensureLoaded(board: board)
        return (comments[board]?.values ?? Dictionary<String, CardComment>().values).filter { $0.taskID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func attach(taskID: String, board: String, filename: String, contentType: String?, data: Data) async throws -> CardAttachment {
        try await ensureLoaded(board: board)
        guard tasks[board]?[taskID] != nil else { throw CardStoreError.taskNotFound(taskID) }
        let id = UUID().uuidString
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let blobs = Self.blobsRoot(arcHome: arcHome)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blobPath = blobs.appendingPathComponent("\(id)-\(safeName)")
        do {
            try data.write(to: blobPath, options: .atomic)
        } catch {
            throw CardStoreError.attachmentWriteFailed(blobPath.path)
        }
        let att = CardAttachment(
            taskID: taskID, filename: safeName,
            storedPath: blobPath.path, contentType: contentType, size: data.count
        )
        let seq = await connection.takeSequence()
        try await publish(kind: Self.attachmentKind, dTag: "\(dTagHead(board))/attachment/\(id)/\(seq)", payload: JSONEncoder.isoDate.encode(att))
        attachments[board, default: [:]][id] = att
        try await appendEvent(taskID: taskID, board: board, runID: nil, kind: "attached", payload: safeName)
        return att
    }

    public func attachments(taskID: String, board: String) async throws -> [CardAttachment] {
        try await ensureLoaded(board: board)
        return (attachments[board]?.values ?? Dictionary<String, CardAttachment>().values).filter { $0.taskID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func events(taskID: String, board: String, limit: Int) async throws -> [CardEvent] {
        try await ensureLoaded(board: board)
        return Array((events[board] ?? []).filter { $0.taskID == taskID }.suffix(limit))
    }

    public func appendEvent(taskID: String, board: String, runID: String?, kind: String, payload: String?) async throws {
        let event = CardEvent(taskID: taskID, runID: runID, kind: kind, payload: payload)
        let seq = await connection.takeSequence()
        try await publish(kind: Self.eventKind, dTag: "\(dTagHead(board))/event/\(event.id)/\(seq)", payload: JSONEncoder.isoDate.encode(event))
        events[board, default: []].append(event)
    }

    public func runs(taskID: String, board: String) async throws -> [CardRun] {
        try await ensureLoaded(board: board)
        return (runs[board]?.values ?? Dictionary<String, CardRun>().values).filter { $0.taskID == taskID }.sorted { $0.attempt < $1.attempt }
    }

    public func deleteBoard(board: String) async throws {
        try await ensureLoaded(board: board)
        try await connection.deleteAll(dTagPrefix: "\(dTagHead(board))/task/", kind: Self.taskKind)
        try await connection.deleteAll(dTagPrefix: "\(dTagHead(board))/run/", kind: Self.runKind)
        try await connection.deleteAll(dTagPrefix: "\(dTagHead(board))/comment/", kind: Self.commentKind)
        try await connection.deleteAll(dTagPrefix: "\(dTagHead(board))/link/", kind: Self.linkKind)
        try await connection.deleteAll(dTagPrefix: "\(dTagHead(board))/event/", kind: Self.eventKind)
        try await connection.deleteAll(dTagPrefix: "\(dTagHead(board))/attachment/", kind: Self.attachmentKind)
        if !CardBoard.reserved.contains(board) {
            try await connection.deleteAll(dTagPrefix: "arc/boards/\(board)/", kind: Self.boardKind)
            boardRows = nil
        }
        tasks[board] = nil
        runs[board] = nil
        comments[board] = nil
        links[board] = nil
        events[board] = nil
        attachments[board] = nil
    }

    // MARK: Board registry (kind 3020, d-tag arc/boards/<id>/<seq>)

    /// Folded board rows; the registry is global (not per-board), so it
    /// gets its own 2-second cache slot.
    private var boardRows: [CardBoard]?
    private var boardsSync = Date.distantPast

    private func ensureBoardsLoaded() async throws {
        if boardRows != nil, Date().timeIntervalSince(boardsSync) < 2 { return }
        var rows: [CardBoard] = []
        var seen: Set<String> = []
        for record in await connection.snapshot(kind: Self.boardKind) {
            guard let dTag = record.dTag, dTag.hasPrefix("arc/boards/") else { continue }
            let parts = dTag.split(separator: "/").map(String.init)
            // arc/boards/<id>/<seq> — highest seq per id wins.
            guard parts.count == 4, let seq = Int(parts[3]) else { continue }
            let id = parts[2]
            if let best = seen.first(where: { $0 == id }), best == id { continue }
            guard let data = record.content.data(using: .utf8),
                  let board = try? JSONDecoder.isoDate.decode(CardBoard.self, from: data)
            else { continue }
            if let idx = rows.firstIndex(where: { $0.id == id }) {
                // Records arrive newest-last per snapshot ordering; keep the
                // row whose d-tag seq is highest.
                rows[idx] = board
            } else {
                rows.append(board)
            }
            seen.insert(id)
        }
        boardRows = rows
        boardsSync = Date()
    }

    public func createBoard(_ board: CardBoard) async throws {
        try await connection.ensureStarted()
        let payload = try JSONEncoder.isoDate.encode(board)
        try await publish(kind: Self.boardKind, dTag: "arc/boards/\(board.id)/1", payload: payload)
        if var rows = boardRows {
            if let i = rows.firstIndex(where: { $0.id == board.id }) { rows[i] = board } else { rows.append(board) }
            boardRows = rows
        }
    }

    public func listBoards() async throws -> [CardBoard] {
        try await ensureBoardsLoaded()
        let reserved = CardBoard(id: CardBoard.standaloneID, name: "Unboarded")
        var rows = (boardRows ?? []).filter { $0.id != CardBoard.standaloneID }
        rows.sort { $0.id < $1.id }
        return [reserved] + rows
    }

    public func removeBoard(id: String) async throws {
        guard !CardBoard.reserved.contains(id) else { return }
        try await connection.ensureStarted()
        try await connection.deleteAll(dTagPrefix: "arc/boards/\(id)/", kind: Self.boardKind)
        boardRows?.removeAll { $0.id == id }
    }

    public func archiveTask(id: String, board: String) async throws -> CardTask {
        try await ensureLoaded(board: board)
        var task = try await taskOrThrow(id: id, board: board)
        task.status = .archived
        if task.completedAt == nil { task.completedAt = Date() }
        try await saveTask(task, board: board)
        try await appendEvent(taskID: id, board: board, runID: nil, kind: "archived", payload: "removed from board columns")
        return task
    }
}

private extension JSONEncoder {
    static let isoDate: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let isoDate: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
