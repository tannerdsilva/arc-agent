import Foundation
import CLMDB

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
///
/// ## Concurrency
///
/// ``LMDBSessionStore`` is an **actor**. Every LMDB operation runs directly on
/// the actor's executor — no dispatch queues and no continuation bridging.
/// Actor isolation serializes all access to the environment, and the
/// environment pointer lives in actor-isolated state, so no `@unchecked
/// Sendable` wrapper is needed.
public actor LMDBSessionStore: SessionStore {

    /// Persistent environment held for the session's lifetime (caller-owned),
    /// or `nil` for transient (open/close per call) operation.
    private let envRef: OpaquePointer?

    /// Create a session store with a persistent environment.
    /// - Parameter envBits: Bit pattern of a pre-opened LMDB environment.
    ///   The caller is responsible for closing the environment when the
    ///   session ends.
    ///
    /// An `OpaquePointer` is not `Sendable`, so the handle crosses the actor
    /// boundary as its bit pattern (`UInt` is `Sendable`) and is reconstructed
    /// here, where it lives in isolated state and is never shared.
    public init(envBits: UInt) {
        self.envRef = UnsafeRawPointer(bitPattern: envBits).map(OpaquePointer.init)
    }

    /// Create a session store with transient (open/close per call) environments.
    public init() {
        self.envRef = nil
    }

    // MARK: - Environment Helper

    /// Execute an operation with an LMDB environment.
    /// Uses the persistent environment if available, otherwise opens/closes
    /// a transient environment for the given session ID.
    private func withEnv<T>(sessionID: String, operation: (OpaquePointer) throws -> T) throws -> T {
        if let ref = envRef {
            return try operation(ref)
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
        try self.withEnv(sessionID: session.id) { env in
            try self.writeSession(env: env, session: session)
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
        return try self.withEnv(sessionID: id) { env in
            let txn = try LMDB.txnBeginRead(env: env)
            defer { LMDB.txnAbort(txn) }

            // Read metadata
            let meta: UInt32
            do {
                meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: false)
            } catch let e as LMDBError where e.rc == MDB_NOTFOUND {
                return nil
            }
            guard let metaBytes = try LMDB.get(env: env, txn: txn, dbi: meta,
                key: [UInt8]("session_meta".utf8)) else {
                return nil
            }
            let sm = try JSONDecoder().decode(SessionMeta.self, from: Data(metaBytes))

            // Read all messages via cursor scan
            let headers = try LMDB.dbiOpen(env: env, txn: txn, name: "headers", create: false)
            let bodies = try LMDB.dbiOpen(env: env, txn: txn, name: "bodies", create: false)
            var messages: [Message] = []
            let cursor = try LMDB.cursorOpen(txn: txn, dbi: headers)
            defer { LMDB.cursorClose(cursor) }

            if let (_, _) = try LMDB.cursorSetRange(cursor: cursor, key: LMDBManager.seqKey(0)) {
                messages.append(try self.decodeMessage(cursor: cursor, bodies: bodies, env: env, txn: txn))
                while let (_, _) = try LMDB.cursorNext(cursor: cursor) {
                    messages.append(try self.decodeMessage(cursor: cursor, bodies: bodies, env: env, txn: txn))
                }
            }

            return Session(
                id: id,
                createdAt: sm.createdAt,
                updatedAt: sm.updatedAt,
                model: sm.model,
                provider: sm.provider,
                messages: messages
            )
        }
    }

    public func update(_ session: Session) async throws {
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
    }

    public func delete(id: String) async throws {
        // If we have a persistent env, delete from there
        if envRef != nil {
            try self.withEnv(sessionID: id) { env in
                let txn = try LMDB.txnBeginWrite(env: env)
                var committed = false
                defer { if !committed { LMDB.txnAbort(txn) } }
                // Try to open and clear each database
                for name in ["meta", "headers", "bodies"] {
                    do {
                        let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: name, create: false)
                        try LMDB.clear(env: env, txn: txn, dbi: dbi)
                    } catch let e as LMDBError where e.rc == MDB_NOTFOUND {
                        continue // Database doesn't exist, skip
                    }
                }
                try LMDB.txnCommit(txn)
                committed = true
            }
        }
        // Also remove from filesystem if it exists there
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
    }

    // MARK: - Private

    /// Write a session's messages to an open environment.
    private func writeSession(env: OpaquePointer, session: Session) throws {
        let txn = try LMDB.txnBeginWrite(env: env)
        var committed = false
        defer { if !committed { LMDB.txnAbort(txn) } }
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
        try LMDB.txnCommit(txn)
        committed = true
    }

    /// Decode a message at the current cursor position by reading the header
    /// and loading the body from the bodies database.
    private func decodeMessage(cursor: OpaquePointer, bodies: UInt32, env: OpaquePointer, txn: OpaquePointer) throws -> Message {
        let (keyBytes, valBytes) = try LMDB.cursorCurrent(cursor: cursor)
        // Corrupt or foreign data must surface a clean storage error, not an
        // out-of-bounds trap on the fixed-size header slice.
        guard valBytes.count == 13 else {
            throw SessionError.storageError(
                "corrupt message header (\(valBytes.count) bytes, expected 13)")
        }
        let hdr = MessageHeader(bytes: valBytes)
        guard let bodyBytes = try LMDB.get(env: env, txn: txn, dbi: bodies, key: keyBytes) else {
            throw SessionError.storageError("missing message body")
        }
        return try JSONDecoder().decode(Message.self, from: Data(bodyBytes))
    }
}

// MARK: - Env Handle Bits

/// Bit pattern of an LMDB environment handle.
///
/// `OpaquePointer` is not `Sendable`; this `UInt` is the Sendable
/// representation used to hand an env handle to an actor (e.g.
/// ``LMDBSessionStore.init(envBits:)``).
func envHandleBits(_ env: OpaquePointer) -> UInt {
    UInt(bitPattern: env)
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
