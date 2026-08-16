import Foundation

/// An LMDB-backed session store using the raw LMDB C API.
///
/// Each session is stored in its own `.mdb` file under `~/.arc/sessions/`.
public struct LMDBSessionStore: SessionStore {

    private let queue: DispatchQueue

    public init() {
        self.queue = DispatchQueue(label: "com.arc-agent.lmdb-sessions", qos: .utility)
    }

    // MARK: - SessionStore

    public func create(_ session: Session) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let env = try LMDBManager.openSession(session.id)
                    defer { LMDB.envClose(env) }
                    let txn = try LMDB.txnBeginWrite(env: env)
                    defer { LMDB.txnAbort(txn) }
                    let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: true)
                    let metaData = try JSONEncoder().encode(SessionMeta(from: session))
                    try LMDB.set(env: env, txn: txn, dbi: meta, key: [UInt8]("session_meta".utf8), value: [UInt8](metaData))
                    try LMDB.txnCommit(txn)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func get(id: String) async throws -> Session? {
        let path = LMDBManager.sessionPath(id)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let env = try LMDBManager.openSession(id)
                    defer { LMDB.envClose(env) }
                    let txn = try LMDB.txnBeginRead(env: env)
                    defer { LMDB.txnAbort(txn) }
                    let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: false)
                    let metaKey = [UInt8]("session_meta".utf8)
                    guard let metaBytes = try LMDB.get(env: env, txn: txn, dbi: meta, key: metaKey) else {
                        continuation.resume(returning: nil as Session?); return
                    }
                    let sessionMeta = try JSONDecoder().decode(SessionMeta.self, from: Data(metaBytes))
                    let msgs = try LMDB.dbiOpen(env: env, txn: txn, name: "messages", create: false)
                    var messages: [Message] = []
                    var seq: UInt64 = 0
                    while true {
                        let key = [UInt8]("\(seq)".utf8)
                        guard try LMDB.exists(env: env, txn: txn, dbi: msgs, key: key) else { break }
                        guard let msgBytes = try LMDB.get(env: env, txn: txn, dbi: msgs, key: key) else { break }
                        messages.append(try JSONDecoder().decode(Message.self, from: Data(msgBytes)))
                        seq += 1
                    }
                    continuation.resume(returning: Session(id: id, createdAt: sessionMeta.createdAt, updatedAt: sessionMeta.updatedAt, model: sessionMeta.model, provider: sessionMeta.provider, messages: messages))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func update(_ session: Session) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let env = try LMDBManager.openSession(session.id)
                    defer { LMDB.envClose(env) }
                    let txn = try LMDB.txnBeginWrite(env: env)
                    defer { LMDB.txnAbort(txn) }
                    let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: true)
                    let metaData = try JSONEncoder().encode(SessionMeta(from: session))
                    try LMDB.set(env: env, txn: txn, dbi: meta, key: [UInt8]("session_meta".utf8), value: [UInt8](metaData))
                    let msgs = try LMDB.dbiOpen(env: env, txn: txn, name: "messages", create: true)
                    var seq: UInt64 = 0
                    while true {
                        let key = [UInt8]("\(seq)".utf8)
                        guard try LMDB.exists(env: env, txn: txn, dbi: msgs, key: key) else { break }
                        try LMDB.del(env: env, txn: txn, dbi: msgs, key: key)
                        seq += 1
                    }
                    for (i, msg) in session.messages.enumerated() {
                        try LMDB.set(env: env, txn: txn, dbi: msgs, key: [UInt8]("\(i)".utf8), value: [UInt8](try JSONEncoder().encode(msg)))
                    }
                    try LMDB.txnCommit(txn)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func delete(id: String) async throws {
        try FileManager.default.removeItem(atPath: LMDBManager.sessionPath(id))
    }

    public func list(limit: Int) async throws -> [Session] {
        let dir = LMDBManager.sessionsDir
        guard FileManager.default.fileExists(atPath: dir) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".mdb") }.sorted().prefix(limit)
        var sessions: [Session] = []
        for file in files {
            let id = file.replacingOccurrences(of: ".mdb", with: "")
            if let s = try await get(id: id) { sessions.append(s) }
        }
        return sessions
    }

    public func appendMessage(sessionID: String, message: Message) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let env = try LMDBManager.openSession(sessionID)
                    defer { LMDB.envClose(env) }
                    let txn = try LMDB.txnBeginWrite(env: env)
                    defer { LMDB.txnAbort(txn) }
                    let msgs = try LMDB.dbiOpen(env: env, txn: txn, name: "messages", create: true)
                    var seq: UInt64 = 0
                    while true {
                        let key = [UInt8]("\(seq)".utf8)
                        guard try LMDB.exists(env: env, txn: txn, dbi: msgs, key: key) else { break }
                        seq += 1
                    }
                    try LMDB.set(env: env, txn: txn, dbi: msgs, key: [UInt8]("\(seq)".utf8), value: [UInt8](try JSONEncoder().encode(message)))
                    let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: true)
                    let metaKey = [UInt8]("session_meta".utf8)
                    if let metaBytes = try LMDB.get(env: env, txn: txn, dbi: meta, key: metaKey) {
                        var sm = try JSONDecoder().decode(SessionMeta.self, from: Data(metaBytes))
                        sm.updatedAt = Date()
                        try LMDB.set(env: env, txn: txn, dbi: meta, key: metaKey, value: [UInt8](try JSONEncoder().encode(sm)))
                    }
                    try LMDB.txnCommit(txn)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct SessionMeta: Codable, Sendable {
    let createdAt: Date
    var updatedAt: Date
    let model: String
    let provider: String
    init(from session: Session) {
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.model = session.model
        self.provider = session.provider
    }
}
