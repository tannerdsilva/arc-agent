import Foundation
import CLMDB

/// A reference type wrapper for an LMDB environment pointer.
/// Required because OpaquePointer is not Sendable.
final class LMDBEnvRef: @unchecked Sendable {
    let env: OpaquePointer
    init(_ env: OpaquePointer) { self.env = env }
}

/// An LMDB-backed session store using a header/body split for messages.
///
/// **Schema per-session .mdb:**
///
/// ```
/// meta database:
///   "session_meta" → JSON(SessionMeta)
///     { createdAt, updatedAt, model, provider, messageCount, totalTokens }
///
/// headers database (fixed-size entries, fast scan):
///   key: UInt64 big-endian (8 bytes, sequence number)
///   val: MessageHeader (13 bytes, fixed-size struct)
///     [role:UInt8][timestamp:UInt64][bodyLength:UInt32]
///
/// bodies database (variable-length, loaded on demand):
///   key: UInt64 big-endian (8 bytes, sequence number)
///   val: JSON(Message) — full message blob
/// ```
///
/// ## Environment Lifecycle
///
/// The session store can operate in two modes:
/// - **Persistent** (preferred): Pass a pre-opened environment via `init(env:)`.
///   The environment is held open for the session's lifetime, avoiding repeated
///   open/close overhead. The caller is responsible for closing the environment.
/// - **Transient** (default): The environment is opened and closed per call.
///   Suitable for one-off operations where no session agent is running.
public struct LMDBSessionStore: SessionStore {

    private let queue: DispatchQueue
    private let envRef: LMDBEnvRef?

    /// Create a session store with a persistent environment.
    /// - Parameter env: A pre-opened LMDB environment. The caller is
    ///   responsible for closing it when the session ends.
    public init(env: OpaquePointer) {
        self.queue = DispatchQueue(label: "com.arc-agent.lmdb-sessions", qos: .utility)
        self.envRef = LMDBEnvRef(env)
    }

    /// Create a session store with transient (open/close per call) environments.
    public init() {
        self.queue = DispatchQueue(label: "com.arc-agent.lmdb-sessions", qos: .utility)
        self.envRef = nil
    }

    // MARK: - Environment Helper

    /// Execute an operation with an LMDB environment.
    /// Uses the persistent environment if available, otherwise opens/closes
    /// a transient environment for the given session ID.
    private func withEnv<T>(sessionID: String, operation: (OpaquePointer) throws -> T) throws -> T {
        if let ref = envRef {
            return try operation(ref.env)
        }
        let env = try LMDBManager.openSession(sessionID)
        defer { LMDB.envClose(env) }
        return try operation(env)
    }

    /// Execute a write transaction. Commits on success, aborts on error.
    /// The transaction is aborted via defer ONLY if commit hasn't happened yet.
    private func withWriteTransaction<T>(env: OpaquePointer, operation: (OpaquePointer) throws -> T) throws -> T {
        let txn = try LMDB.txnBeginWrite(env: env)
        var committed = false
        defer {
            if !committed { LMDB.txnAbort(txn) }
        }
        let result = try operation(txn)
        try LMDB.txnCommit(txn)
        committed = true
        return result
    }

    // MARK: - SessionStore

    public func create(_ session: Session) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.withEnv(sessionID: session.id) { env in
                        try self.withWriteTransaction(env: env) { txn in
                            let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: true)
                            let sm = SessionMeta(
                                createdAt: session.createdAt,
                                updatedAt: session.updatedAt,
                                model: session.model,
                                provider: session.provider,
                                messageCount: UInt32(session.messages.count),
                                totalTokens: 0
                            )
                            try LMDB.set(env: env, txn: txn, dbi: meta,
                                key: [UInt8]("session_meta".utf8),
                                value: [UInt8](try JSONEncoder().encode(sm)))

                            // Write messages as header + body pairs
                            let headers = try LMDB.dbiOpen(env: env, txn: txn, name: "headers", create: true)
                            let bodies = try LMDB.dbiOpen(env: env, txn: txn, name: "bodies", create: true)
                            for (i, msg) in session.messages.enumerated() {
                                let seq = LMDBManager.seqKey(UInt64(i))
                                let bodyData = try JSONEncoder().encode(msg)
                                let hdr = MessageHeader(
                                    role: msg.role.headerByte,
                                    timestamp: 0,
                                    bodyLength: UInt32(bodyData.count)
                                )
                                try LMDB.set(env: env, txn: txn, dbi: headers, key: seq, value: hdr.bytes)
                                try LMDB.set(env: env, txn: txn, dbi: bodies, key: seq, value: [UInt8](bodyData))
                            }
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func get(id: String) async throws -> Session? {
        // Check if the session directory exists (transient mode) or
        // if we have a persistent env (envRef is set)
        if envRef == nil {
            let path = LMDBManager.sessionPath(id)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.withEnv(sessionID: id) { env in
                        let txn = try LMDB.txnBeginRead(env: env)
                        defer { LMDB.txnAbort(txn) }

                        // Read metadata
                        let meta: UInt32
                        do {
                            meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: false)
                        } catch let e as LMDBError where e.rc == MDB_NOTFOUND {
                            continuation.resume(returning: nil as Session?); return
                        }
                        guard let metaBytes = try LMDB.get(env: env, txn: txn, dbi: meta,
                            key: [UInt8]("session_meta".utf8)) else {
                            continuation.resume(returning: nil as Session?); return
                        }
                        let sm = try JSONDecoder().decode(SessionMeta.self, from: Data(metaBytes))

                        // Read all messages via cursor scan
                        let headers = try LMDB.dbiOpen(env: env, txn: txn, name: "headers", create: false)
                        let bodies = try LMDB.dbiOpen(env: env, txn: txn, name: "bodies", create: false)
                        var messages: [Message] = []
                        let cursor = try LMDB.cursorOpen(txn: txn, dbi: headers)
                        defer { LMDB.cursorClose(cursor) }

                        if let (_, _) = try LMDB.cursorSetRange(cursor: cursor, key: LMDBManager.seqKey(0)) {
                            messages.append(try decodeMessage(cursor: cursor, bodies: bodies, env: env, txn: txn))
                            while let (_, _) = try LMDB.cursorNext(cursor: cursor) {
                                messages.append(try decodeMessage(cursor: cursor, bodies: bodies, env: env, txn: txn))
                            }
                        }

                        continuation.resume(returning: Session(
                            id: id,
                            createdAt: sm.createdAt,
                            updatedAt: sm.updatedAt,
                            model: sm.model,
                            provider: sm.provider,
                            messages: messages
                        ))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func update(_ session: Session) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.withEnv(sessionID: session.id) { env in
                        try self.withWriteTransaction(env: env) { txn in
                            // Update metadata
                            let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: true)
                            let sm = SessionMeta(
                                createdAt: session.createdAt,
                                updatedAt: session.updatedAt,
                                model: session.model,
                                provider: session.provider,
                                messageCount: UInt32(session.messages.count),
                                totalTokens: 0
                            )
                            try LMDB.set(env: env, txn: txn, dbi: meta,
                                key: [UInt8]("session_meta".utf8),
                                value: [UInt8](try JSONEncoder().encode(sm)))

                            // Clear existing messages
                            let headers = try LMDB.dbiOpen(env: env, txn: txn, name: "headers", create: true)
                            let bodies = try LMDB.dbiOpen(env: env, txn: txn, name: "bodies", create: true)
                            let cursor = try LMDB.cursorOpen(txn: txn, dbi: headers)
                            defer { LMDB.cursorClose(cursor) }
                            if let (k, _) = try LMDB.cursorSetRange(cursor: cursor, key: LMDBManager.seqKey(0)) {
                                try LMDB.del(env: env, txn: txn, dbi: headers, key: k)
                                try LMDB.del(env: env, txn: txn, dbi: bodies, key: k)
                                while let (k2, _) = try LMDB.cursorNext(cursor: cursor) {
                                    try LMDB.del(env: env, txn: txn, dbi: headers, key: k2)
                                    try LMDB.del(env: env, txn: txn, dbi: bodies, key: k2)
                                }
                            }

                            // Write new messages
                            for (i, msg) in session.messages.enumerated() {
                                let seq = LMDBManager.seqKey(UInt64(i))
                                let bodyData = try JSONEncoder().encode(msg)
                                let hdr = MessageHeader(
                                    role: msg.role.headerByte,
                                    timestamp: 0,
                                    bodyLength: UInt32(bodyData.count)
                                )
                                try LMDB.set(env: env, txn: txn, dbi: headers, key: seq, value: hdr.bytes)
                                try LMDB.set(env: env, txn: txn, dbi: bodies, key: seq, value: [UInt8](bodyData))
                            }
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func delete(id: String) async throws {
        let path = LMDBManager.sessionPath(id)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    public func list(limit: Int) async throws -> [Session] {
        let dir = LMDBManager.sessionsDir
        guard FileManager.default.fileExists(atPath: dir) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir)
        let sessionDirs = contents.filter { name in
            let fullPath = dir + "/" + name
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }.sorted().prefix(limit)
        var sessions: [Session] = []
        for name in sessionDirs {
            if let s = try await get(id: name) { sessions.append(s) }
        }
        return sessions
    }

    public func appendMessage(sessionID: String, message: Message) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.withEnv(sessionID: sessionID) { env in
                        try self.withWriteTransaction(env: env) { txn in
                            // Find the next sequence number
                            let headers = try LMDB.dbiOpen(env: env, txn: txn, name: "headers", create: true)
                            let bodies = try LMDB.dbiOpen(env: env, txn: txn, name: "bodies", create: true)
                            let nextSeq: UInt64
                            let cursor = try LMDB.cursorOpen(txn: txn, dbi: headers)
                            defer { LMDB.cursorClose(cursor) }
                            if let (lastKey, _) = try LMDB.cursorLast(cursor: cursor) {
                                nextSeq = LMDBManager.seqFromKey(lastKey) + 1
                            } else {
                                nextSeq = 0
                            }

                            // Write header + body
                            let seq = LMDBManager.seqKey(nextSeq)
                            let bodyData = try JSONEncoder().encode(message)
                            let hdr = MessageHeader(
                                role: message.role.headerByte,
                                timestamp: 0,
                                bodyLength: UInt32(bodyData.count)
                            )
                            try LMDB.set(env: env, txn: txn, dbi: headers, key: seq, value: hdr.bytes)
                            try LMDB.set(env: env, txn: txn, dbi: bodies, key: seq, value: [UInt8](bodyData))

                            // Update metadata
                            let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: true)
                            let metaKey = [UInt8]("session_meta".utf8)
                            if let metaBytes = try LMDB.get(env: env, txn: txn, dbi: meta, key: metaKey) {
                                var sm = try JSONDecoder().decode(SessionMeta.self, from: Data(metaBytes))
                                sm.updatedAt = Date()
                                sm.messageCount += 1
                                try LMDB.set(env: env, txn: txn, dbi: meta, key: metaKey,
                                    value: [UInt8](try JSONEncoder().encode(sm)))
                            }
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Private

    /// Decode a message at the current cursor position by reading the header
    /// and loading the body from the bodies database.
    private func decodeMessage(cursor: OpaquePointer, bodies: UInt32, env: OpaquePointer, txn: OpaquePointer) throws -> Message {
        let (keyBytes, valBytes) = try LMDB.cursorCurrent(cursor: cursor)
        let hdr = MessageHeader(bytes: valBytes)
        guard let bodyBytes = try LMDB.get(env: env, txn: txn, dbi: bodies, key: keyBytes) else {
            throw LMDBError(rc: -1)
        }
        return try JSONDecoder().decode(Message.self, from: Data(bodyBytes))
    }
}

// MARK: - MessageHeader

/// Fixed-size binary header for a message in the headers database.
///
/// Layout (13 bytes total):
/// ```
/// [0]    role: UInt8       — 0=system, 1=user, 2=assistant, 3=tool
/// [1-8]  timestamp: UInt64 — Unix timestamp in milliseconds (big-endian)
/// [9-12] bodyLength: UInt32 — byte length of the body in the bodies database (big-endian)
/// ```
struct MessageHeader {
    let role: UInt8
    let timestamp: UInt64
    let bodyLength: UInt32

    var bytes: [UInt8] {
        var ts = timestamp.bigEndian
        var bl = bodyLength.bigEndian
        return [role] + withUnsafeBytes(of: &ts) { [UInt8]($0) } + withUnsafeBytes(of: &bl) { [UInt8]($0) }
    }

    init(role: UInt8, timestamp: UInt64, bodyLength: UInt32) {
        self.role = role
        self.timestamp = timestamp
        self.bodyLength = bodyLength
    }

    init(bytes: [UInt8]) {
        assert(bytes.count == 13, "MessageHeader must be exactly 13 bytes")
        self.role = bytes[0]
        // Copy to aligned storage before loading
        var ts: UInt64 = 0
        var bl: UInt32 = 0
        withUnsafeMutableBytes(of: &ts) { dest in
            dest.copyBytes(from: bytes[1..<9])
        }
        withUnsafeMutableBytes(of: &bl) { dest in
            dest.copyBytes(from: bytes[9..<13])
        }
        self.timestamp = UInt64(bigEndian: ts)
        self.bodyLength = UInt32(bigEndian: bl)
    }
}

// MARK: - Role → Header Byte

extension Message.Role {
    var headerByte: UInt8 {
        switch self {
        case .system: return 0
        case .user: return 1
        case .assistant: return 2
        case .tool: return 3
        }
    }
}

// MARK: - SessionMeta

struct SessionMeta: Codable, Sendable {
    let createdAt: Date
    var updatedAt: Date
    let model: String
    let provider: String
    var messageCount: UInt32
    var totalTokens: UInt32
}
