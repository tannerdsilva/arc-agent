import Foundation
import Logging

// ==========================================================================
// CardProxy — CardStore-level forwarding to the daemon's HTTP API.
//
// `KanbanProxy` covers only `kanban` *tool* calls; every other path that
// touches a card store (worker context resolution, non-tool writes, direct
// store use in a one-shot) opened a second tessera tunnel under the same
// WireGuard static key — and each new tunnel roams the relay's peer index,
// resetting the other process's KCP control block and dropping its in-flight
// echo frames ("write echo never landed … forcing reconnect").
//
// `ProxiedCardStore` closes that gap: when a daemon is running, a non-daemon
// process gets a card store whose every verb executes on the daemon's own
// tunnel over `POST /v1/card`. When the daemon is NOT reachable, the store
// falls back to the process's local backend (TesseraCardStore — its own
// tunnel — or FileCardStore), so a standalone CLI or worker keeps working
// unchanged. The fallback is per-call: the first refused connection builds
// the local backend once and all later verbs ride it (and any verb that
// fails over after the daemon goes away mid-run does the same).
//
// The daemon process itself never proxies (``CardStores/isDaemonProcess``),
// or its own store resolution would loop back through its HTTP server.
// ==========================================================================

// MARK: - Wire format

/// Shared JSON coding for the card-proxy wire. Dates ride as milliseconds
/// since 1970 (FileCardStore's strategy); both ends are arc so the format
/// is private to this protocol.
public enum CardProxyWire {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    /// Encode a Codable value into a JSON-serializable object for embedding
    /// in a request `params` dictionary or a response `result` field.
    public static func embed<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    /// Decode an embedded Codable value back from its JSON object form.
    /// Objects, arrays, and null decode directly; top-level scalars cannot
    /// ride JSONSerialization — use ``scalar(_:as:)`` for those.
    public static func extract<T: Decodable>(_ type: T.Type, _ any: Any?) throws -> T {
        let json: Any = any ?? NSNull()
        switch json {
        case is NSNull, is [Any], is [String: Any]:
            break
        default:
            throw CardProxyError.transport("cannot decode \(T.self) from a scalar")
        }
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Decode a scalar (Bool/String/Int) result field — JSONSerialization
    /// cannot express these at the top level, so they bypass JSONDecoder.
    public static func scalar<T>(_ any: Any?, as type: T.Type) throws -> T {
        guard let v = any as? T else {
            throw CardProxyError.transport("scalar result shape")
        }
        return v
    }

    /// A daemon-side store failure, structured so the client can rethrow the
    /// same ``CardStoreError`` the local backend would have thrown.
    struct Failure: Codable {
        let kind: String
        let args: [String]
        let message: String
    }

    static func failureEnvelope(_ error: CardStoreError) -> [String: Any] {
        let (kind, args): (String, [String])
        switch error {
        case .taskNotFound(let id): (kind, args) = ("taskNotFound", [id])
        case .runNotFound(let taskID, let runID): (kind, args) = ("runNotFound", [taskID, runID])
        case .taskNotClaimable(let id, let status): (kind, args) = ("taskNotClaimable", [id, status.rawValue])
        case .taskNotRunning(let id, let status): (kind, args) = ("taskNotRunning", [id, status.rawValue])
        case .parentCycle(let parent, let child): (kind, args) = ("parentCycle", [parent, child])
        case .parentNotFound(let id): (kind, args) = ("parentNotFound", [id])
        case .phantomCreatedCard(let id): (kind, args) = ("phantomCreatedCard", [id])
        case .attachmentWriteFailed(let id): (kind, args) = ("attachmentWriteFailed", [id])
        case .invalidTransition(let why): (kind, args) = ("invalidTransition", [why])
        }
        return ["ok": false, "failure": ["kind": kind, "args": args, "message": cardStoreMessage(error)]]
    }

    static func cardStoreMessage(_ error: CardStoreError) -> String {
        switch error {
        case .taskNotFound(let id): return "task \(id) not found"
        case .runNotFound(let taskID, let runID): return "run \(runID) not found on task \(taskID)"
        case .taskNotClaimable(let id, let status): return "task \(id) not claimable (status \(status.rawValue))"
        case .taskNotRunning(let id, let status): return "task \(id) not running (status \(status.rawValue))"
        case .parentCycle(let parent, let child): return "linking \(child) under \(parent) would create a dependency cycle"
        case .parentNotFound(let id): return "parent task \(id) not found"
        case .phantomCreatedCard(let id): return "created card \(id) does not exist"
        case .attachmentWriteFailed(let id): return "attachment write failed: \(id)"
        case .invalidTransition(let why): return why
        }
    }

    static func cardStoreError(from failure: Failure) -> CardStoreError? {
        let a = failure.args
        switch failure.kind {
        case "taskNotFound" where a.count >= 1: return .taskNotFound(a[0])
        case "runNotFound" where a.count >= 2: return .runNotFound(taskID: a[0], runID: a[1])
        case "taskNotClaimable" where a.count >= 2: return .taskNotClaimable(a[0], status: CardStatus(rawValue: a[1]) ?? .running)
        case "taskNotRunning" where a.count >= 2: return .taskNotRunning(a[0], status: CardStatus(rawValue: a[1]) ?? .running)
        case "parentCycle" where a.count >= 2: return .parentCycle(parent: a[0], child: a[1])
        case "parentNotFound" where a.count >= 1: return .parentNotFound(a[0])
        case "phantomCreatedCard" where a.count >= 1: return .phantomCreatedCard(a[0])
        case "attachmentWriteFailed" where a.count >= 1: return .attachmentWriteFailed(a[0])
        default: return nil
        }
    }
}

/// Transport-level proxy failure — the ONLY condition under which the
/// proxied store falls back to its local backend. A daemon-side store
/// error is structured and rethrown instead (the daemon is running and its
/// answer is authoritative).
public enum CardProxyError: Error, Equatable {
    case transport(String)
}

// MARK: - Param helpers

private func param(_ params: [String: Any], _ key: String) throws -> String {
    guard let v = params[key] as? String, !v.isEmpty else {
        throw CardProxyError.transport("param '\(key)' missing")
    }
    return v
}

private func optParam(_ params: [String: Any], _ key: String) -> String? {
    (params[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
}

private func intParam(_ params: [String: Any], _ key: String) throws -> Int {
    guard let v = params[key] as? Int else {
        throw CardProxyError.transport("param '\(key)' missing")
    }
    return v
}

private func optIntParam(_ params: [String: Any], _ key: String) -> Int? {
    params[key] as? Int
}

private func boolParam(_ params: [String: Any], _ key: String, default def: Bool) -> Bool {
    params[key] as? Bool ?? def
}

private func strArray(_ params: [String: Any], _ key: String) -> [String] {
    (params[key] as? [Any])?.compactMap { $0 as? String } ?? []
}

private func optDataParam(_ params: [String: Any], _ key: String) throws -> Data? {
    guard let b64 = optParam(params, key) else { return nil }
    guard let data = Data(base64Encoded: b64) else {
        throw CardProxyError.transport("param '\(key)' is not base64")
    }
    return data
}

// MARK: - ProxiedCardStore

/// A ``CardStore`` that forwards every verb to the daemon over
/// `POST /v1/card`, falling back to the process's local backend on any
/// transport failure. See the module header for why.
public actor ProxiedCardStore: CardStore {

    private let host: String
    private let port: Int
    private let token: String
    /// Test seam: an explicit fallback backend. Nil in production, where the
    /// fallback resolves from arc config on first need.
    private let fallbackFactory: (@Sendable () async -> (any CardStore))?
    /// The local backend, built lazily on the first fallback need — never
    /// eagerly, so a worker beside a live daemon never opens a tunnel at all.
    private var local: (any CardStore)?

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
        self.fallbackFactory = nil
    }

    /// Test-only initializer with an explicit fallback backend.
    init(host: String, port: Int, token: String, fallback: @escaping @Sendable () async -> (any CardStore)) {
        self.host = host
        self.port = port
        self.token = token
        self.fallbackFactory = fallback
    }

    // MARK: Transport

    private func ensureLocal() async throws -> any CardStore {
        if let local { return local }
        let backend: any CardStore
        if let fallbackFactory {
            backend = await fallbackFactory()
        } else {
            backend = await CardStores.localBackend()
        }
        local = backend
        Logger(label: "arc.card-proxy").warning("daemon card proxy unreachable — falling back to the local backend (own tunnel)")
        return backend
    }

    /// POST one verb. Returns the decoded `result` field on success; throws
    /// ``CardProxyError/transport`` when the daemon is unreachable (the
    /// caller falls back) and the structured ``CardStoreError`` when the
    /// daemon answered with a store-level failure (the caller rethrows).
    private func remote(verb: String, params: [String: Any]) async throws -> Any? {
        guard let url = URL(string: "http://\(host):\(port)/v1/card") else {
            throw CardProxyError.transport("bad proxy URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["verb": verb, "params": params])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CardProxyError.transport("connect failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw CardProxyError.transport("non-HTTP reply")
        }
        guard http.statusCode == 200 else {
            throw CardProxyError.transport("HTTP \(http.statusCode)")
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CardProxyError.transport("unparseable reply")
        }
        if decoded["ok"] as? Bool == true { return decoded["result"] }
        if let raw = decoded["failure"] as? [String: Any],
           let failure = try? CardProxyWire.decoder.decode(CardProxyWire.Failure.self, from: JSONSerialization.data(withJSONObject: raw)),
           let storeError = CardProxyWire.cardStoreError(from: failure) {
            throw storeError
        }
        throw CardProxyError.transport("malformed reply")
    }

    /// Forward a verb with a decodable result; fall back locally on
    /// transport failure.
    private func proxied<T>(
        _ verb: String, _ params: [String: Any],
        decode: (Any?) throws -> T,
        local: (any CardStore) async throws -> T
    ) async throws -> T {
        do {
            return try decode(try await remote(verb: verb, params: params))
        } catch let error as CardStoreError {
            throw error  // store-level failure from the daemon: rethrow, never fall back
        } catch is CardProxyError {
            return try await local(ensureLocal())
        } catch {
            throw CardProxyError.transport("\(verb): \(error)")
        }
    }

    /// Forward a void verb; fall back locally on transport failure.
    private func proxiedVoid(
        _ verb: String, _ params: [String: Any],
        local: (any CardStore) async throws -> Void
    ) async throws {
        do {
            _ = try await remote(verb: verb, params: params)
        } catch is CardProxyError {
            _ = try await local(ensureLocal())
        }
    }

    // MARK: Task verbs

    public func createTask(_ task: CardTask, board: String) async throws -> CardTask {
        try await proxied("createTask", ["task": CardProxyWire.embed(task), "board": board], decode: { try CardProxyWire.extract(CardTask.self, $0) }) {
            try await $0.createTask(task, board: board)
        }
    }

    public func getTask(id: String, board: String) async throws -> CardTask? {
        try await proxied("getTask", ["id": id, "board": board], decode: { try CardProxyWire.extract(Optional<CardTask>.self, $0) }) {
            try await $0.getTask(id: id, board: board)
        }
    }

    public func listTasks(board: String, filter: CardListFilter) async throws -> [CardTask] {
        let filterParams: [String: Any] = [
            "assignee": filter.assignee ?? NSNull(),
            "status": filter.status?.rawValue ?? NSNull(),
            "tenant": filter.tenant ?? NSNull(),
            "includeArchived": filter.includeArchived,
            "limit": filter.limit,
        ]
        return try await proxied("listTasks", ["board": board, "filter": filterParams], decode: { try CardProxyWire.extract([CardTask].self, $0) }) {
            try await $0.listTasks(board: board, filter: filter)
        }
    }

    public func saveTask(_ task: CardTask, board: String) async throws {
        try await proxiedVoid("saveTask", ["task": CardProxyWire.embed(task), "board": board]) {
            try await $0.saveTask(task, board: board)
        }
    }

    // MARK: Claim / complete / block / fail

    public func claimTask(id: String, board: String, profile: String?) async throws -> (CardTask, CardRun) {
        try await proxied("claimTask", ["id": id, "board": board, "profile": profile ?? NSNull()], decode: { any in
            guard let arr = any as? [Any], arr.count == 2 else {
                throw CardProxyError.transport("claimTask result shape")
            }
            return (try CardProxyWire.extract(CardTask.self, arr[0]), try CardProxyWire.extract(CardRun.self, arr[1]))
        }) {
            try await $0.claimTask(id: id, board: board, profile: profile)
        }
    }

    public func completeTask(
        id: String, board: String, runID: String,
        summary: String?, metadata: [String: String]?,
        createdCards: [String], artifacts: [String]
    ) async throws -> (CardTask, CardRun) {
        let params: [String: Any] = [
            "id": id, "board": board, "run_id": runID,
            "summary": summary ?? NSNull(),
            "metadata": metadata ?? NSNull(),
            "created_cards": createdCards,
            "artifacts": artifacts,
        ]
        return try await proxied("completeTask", params, decode: { any in
            guard let arr = any as? [Any], arr.count == 2 else {
                throw CardProxyError.transport("completeTask result shape")
            }
            return (try CardProxyWire.extract(CardTask.self, arr[0]), try CardProxyWire.extract(CardRun.self, arr[1]))
        }) {
            try await $0.completeTask(id: id, board: board, runID: runID, summary: summary, metadata: metadata, createdCards: createdCards, artifacts: artifacts)
        }
    }

    public func blockTask(
        id: String, board: String, runID: String?,
        kind: CardBlockKind?, reason: String?
    ) async throws -> (CardTask, CardRun?) {
        let params: [String: Any] = [
            "id": id, "board": board, "run_id": runID ?? NSNull(),
            "kind": kind?.rawValue ?? NSNull(), "reason": reason ?? NSNull(),
        ]
        return try await proxied("blockTask", params, decode: { any in
            guard let arr = any as? [Any], arr.count == 2 else {
                throw CardProxyError.transport("blockTask result shape")
            }
            return (try CardProxyWire.extract(CardTask.self, arr[0]), try CardProxyWire.extract(Optional<CardRun>.self, arr[1]))
        }) {
            try await $0.blockTask(id: id, board: board, runID: runID, kind: kind, reason: reason)
        }
    }

    public func unblockTask(id: String, board: String) async throws -> CardTask {
        try await proxied("unblockTask", ["id": id, "board": board], decode: { try CardProxyWire.extract(CardTask.self, $0) }) {
            try await $0.unblockTask(id: id, board: board)
        }
    }

    public func failTask(
        id: String, board: String, runID: String?,
        outcome: CardRunOutcome, error: String?
    ) async throws -> (CardTask, CardRun?, Bool) {
        let params: [String: Any] = [
            "id": id, "board": board, "run_id": runID ?? NSNull(),
            "outcome": outcome.rawValue, "error": error ?? NSNull(),
        ]
        return try await proxied("failTask", params, decode: { any in
            guard let arr = any as? [Any], arr.count == 3 else {
                throw CardProxyError.transport("failTask result shape")
            }
            return (
                try CardProxyWire.extract(CardTask.self, arr[0]),
                try CardProxyWire.extract(Optional<CardRun>.self, arr[1]),
                try CardProxyWire.scalar(arr[2], as: Bool.self)
            )
        }) {
            try await $0.failTask(id: id, board: board, runID: runID, outcome: outcome, error: error)
        }
    }

    public func heartbeat(id: String, board: String, runID: String?) async throws {
        try await proxiedVoid("heartbeat", ["id": id, "board": board, "run_id": runID ?? NSNull()]) {
            try await $0.heartbeat(id: id, board: board, runID: runID)
        }
    }

    // MARK: Links

    public func link(parentID: String, childID: String, board: String) async throws {
        try await proxiedVoid("link", ["parent_id": parentID, "child_id": childID, "board": board]) {
            try await $0.link(parentID: parentID, childID: childID, board: board)
        }
    }

    public func parentIDs(of taskID: String, board: String) async throws -> [String] {
        try await proxied("parentIDs", ["task_id": taskID, "board": board], decode: { try CardProxyWire.extract([String].self, $0) }) {
            try await $0.parentIDs(of: taskID, board: board)
        }
    }

    public func childIDs(of taskID: String, board: String) async throws -> [String] {
        try await proxied("childIDs", ["task_id": taskID, "board": board], decode: { try CardProxyWire.extract([String].self, $0) }) {
            try await $0.childIDs(of: taskID, board: board)
        }
    }

    public func recomputeReady(board: String) async throws -> [String] {
        try await proxied("recomputeReady", ["board": board], decode: { try CardProxyWire.extract([String].self, $0) }) {
            try await $0.recomputeReady(board: board)
        }
    }

    // MARK: Comments / attachments / events / runs

    public func addComment(taskID: String, board: String, author: String, body: String) async throws -> CardComment {
        try await proxied("addComment", ["task_id": taskID, "board": board, "author": author, "body": body], decode: { try CardProxyWire.extract(CardComment.self, $0) }) {
            try await $0.addComment(taskID: taskID, board: board, author: author, body: body)
        }
    }

    public func comments(taskID: String, board: String) async throws -> [CardComment] {
        try await proxied("comments", ["task_id": taskID, "board": board], decode: { try CardProxyWire.extract([CardComment].self, $0) }) {
            try await $0.comments(taskID: taskID, board: board)
        }
    }

    public func attach(taskID: String, board: String, filename: String, contentType: String?, data: Data) async throws -> CardAttachment {
        let params: [String: Any] = [
            "task_id": taskID, "board": board, "filename": filename,
            "content_type": contentType ?? NSNull(),
            "data": data.base64EncodedString(),
        ]
        return try await proxied("attach", params, decode: { try CardProxyWire.extract(CardAttachment.self, $0) }) {
            try await $0.attach(taskID: taskID, board: board, filename: filename, contentType: contentType, data: data)
        }
    }

    public func attachments(taskID: String, board: String) async throws -> [CardAttachment] {
        try await proxied("attachments", ["task_id": taskID, "board": board], decode: { try CardProxyWire.extract([CardAttachment].self, $0) }) {
            try await $0.attachments(taskID: taskID, board: board)
        }
    }

    public func events(taskID: String, board: String, limit: Int) async throws -> [CardEvent] {
        try await proxied("events", ["task_id": taskID, "board": board, "limit": limit], decode: { try CardProxyWire.extract([CardEvent].self, $0) }) {
            try await $0.events(taskID: taskID, board: board, limit: limit)
        }
    }

    public func appendEvent(taskID: String, board: String, runID: String?, kind: String, payload: String?) async throws {
        let params: [String: Any] = [
            "task_id": taskID, "board": board, "run_id": runID ?? NSNull(),
            "kind": kind, "payload": payload ?? NSNull(),
        ]
        try await proxiedVoid("appendEvent", params) {
            try await $0.appendEvent(taskID: taskID, board: board, runID: runID, kind: kind, payload: payload)
        }
    }

    public func runs(taskID: String, board: String) async throws -> [CardRun] {
        try await proxied("runs", ["task_id": taskID, "board": board], decode: { try CardProxyWire.extract([CardRun].self, $0) }) {
            try await $0.runs(taskID: taskID, board: board)
        }
    }

    public func deleteBoard(board: String) async throws {
        try await proxiedVoid("deleteBoard", ["board": board]) {
            try await $0.deleteBoard(board: board)
        }
    }

    // ── Board registry & archive: no remote wire verb — the tool layer
    // (which workers always go through) executes these daemon-side via the
    // whole-call proxy. Direct store consumers here fall back locally.

    public func createBoard(_ board: CardBoard) async throws {
        try await ensureLocal().createBoard(board)
    }

    public func listBoards() async throws -> [CardBoard] {
        try await ensureLocal().listBoards()
    }

    public func removeBoard(id: String) async throws {
        try await ensureLocal().removeBoard(id: id)
    }

    public func archiveTask(id: String, board: String) async throws -> CardTask {
        try await ensureLocal().archiveTask(id: id, board: board)
    }
}

// MARK: - Daemon-side executor

/// Executes one proxied verb against the daemon's own store. Lives here so
/// the HTTP layer stays transport-only and the mapping is unit-testable.
public enum CardProxyExecutor {

    /// Dispatch one verb. Returns the JSON-embedded `result` value on
    /// success; throws for anything the HTTP layer should report as a
    /// server error (the client then falls back to its local backend).
    public static func dispatch(verb: String, params: [String: Any], store: any CardStore) async throws -> Any? {
        switch verb {
        case "createTask":
            let task = try CardProxyWire.extract(CardTask.self, params["task"])
            return try CardProxyWire.embed(try await store.createTask(task, board: try param(params, "board")))
        case "getTask":
            return try CardProxyWire.embed(try await store.getTask(id: try param(params, "id"), board: try param(params, "board")))
        case "listTasks":
            guard let raw = params["filter"] as? [String: Any] else {
                throw CardProxyError.transport("param 'filter' missing")
            }
            let filter = CardListFilter(
                assignee: raw["assignee"] as? String,
                status: (raw["status"] as? String).flatMap(CardStatus.init(rawValue:)),
                tenant: raw["tenant"] as? String,
                includeArchived: boolParam(raw, "includeArchived", default: false),
                limit: optIntParam(raw, "limit") ?? 50
            )
            return try CardProxyWire.embed(try await store.listTasks(board: try param(params, "board"), filter: filter))
        case "saveTask":
            let task = try CardProxyWire.extract(CardTask.self, params["task"])
            try await store.saveTask(task, board: try param(params, "board"))
            return nil
        case "claimTask":
            let (task, run) = try await store.claimTask(id: try param(params, "id"), board: try param(params, "board"), profile: optParam(params, "profile"))
            return [try CardProxyWire.embed(task), try CardProxyWire.embed(run)]
        case "completeTask":
            let (task, run) = try await store.completeTask(
                id: try param(params, "id"), board: try param(params, "board"),
                runID: try param(params, "run_id"),
                summary: optParam(params, "summary"),
                metadata: params["metadata"] as? [String: String],
                createdCards: strArray(params, "created_cards"),
                artifacts: strArray(params, "artifacts")
            )
            return [try CardProxyWire.embed(task), try CardProxyWire.embed(run)]
        case "blockTask":
            let kind = optParam(params, "kind").flatMap(CardBlockKind.init(rawValue:))
            let (task, run) = try await store.blockTask(
                id: try param(params, "id"), board: try param(params, "board"),
                runID: optParam(params, "run_id"), kind: kind, reason: optParam(params, "reason")
            )
            return [try CardProxyWire.embed(task), (try? run.map { try CardProxyWire.embed($0) }) ?? NSNull()]
        case "unblockTask":
            return try CardProxyWire.embed(try await store.unblockTask(id: try param(params, "id"), board: try param(params, "board")))
        case "failTask":
            let (task, run, tripped) = try await store.failTask(
                id: try param(params, "id"), board: try param(params, "board"),
                runID: optParam(params, "run_id"),
                outcome: (optParam(params, "outcome")).flatMap(CardRunOutcome.init(rawValue:)) ?? .crashed,
                error: optParam(params, "error")
            )
            return [try CardProxyWire.embed(task), (try? run.map { try CardProxyWire.embed($0) }) ?? NSNull(), tripped]
        case "heartbeat":
            try await store.heartbeat(id: try param(params, "id"), board: try param(params, "board"), runID: optParam(params, "run_id"))
            return nil
        case "link":
            try await store.link(parentID: try param(params, "parent_id"), childID: try param(params, "child_id"), board: try param(params, "board"))
            return nil
        case "parentIDs":
            return try CardProxyWire.embed(try await store.parentIDs(of: try param(params, "task_id"), board: try param(params, "board")))
        case "childIDs":
            return try CardProxyWire.embed(try await store.childIDs(of: try param(params, "task_id"), board: try param(params, "board")))
        case "recomputeReady":
            return try CardProxyWire.embed(try await store.recomputeReady(board: try param(params, "board")))
        case "addComment":
            let comment = try await store.addComment(
                taskID: try param(params, "task_id"), board: try param(params, "board"),
                author: try param(params, "author"), body: try param(params, "body")
            )
            return try CardProxyWire.embed(comment)
        case "comments":
            return try CardProxyWire.embed(try await store.comments(taskID: try param(params, "task_id"), board: try param(params, "board")))
        case "attach":
            let attachment = try await store.attach(
                taskID: try param(params, "task_id"), board: try param(params, "board"),
                filename: try param(params, "filename"),
                contentType: optParam(params, "content_type"),
                data: try optDataParam(params, "data") ?? Data()
            )
            return try CardProxyWire.embed(attachment)
        case "attachments":
            return try CardProxyWire.embed(try await store.attachments(taskID: try param(params, "task_id"), board: try param(params, "board")))
        case "events":
            return try CardProxyWire.embed(try await store.events(taskID: try param(params, "task_id"), board: try param(params, "board"), limit: try intParam(params, "limit")))
        case "appendEvent":
            try await store.appendEvent(
                taskID: try param(params, "task_id"), board: try param(params, "board"),
                runID: optParam(params, "run_id"),
                kind: try param(params, "kind"), payload: optParam(params, "payload")
            )
            return nil
        case "runs":
            return try CardProxyWire.embed(try await store.runs(taskID: try param(params, "task_id"), board: try param(params, "board")))
        case "deleteBoard":
            try await store.deleteBoard(board: try param(params, "board"))
            return nil
        default:
            throw CardProxyError.transport("unknown verb '\(verb)'")
        }
    }
}
