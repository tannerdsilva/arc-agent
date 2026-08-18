import Foundation
import CLMDB

/// An LMDB-backed memory provider using the raw LMDB C API.
///
/// ## The EACCES bug and its fix
///
/// `readMemory()` runs on **every** chat turn (memory is injected into the
/// system prompt). It opens a **read-only** transaction. The original code
/// called `dbiOpen(create: true)` inside that RO txn. LMDB only permits
/// creating a named database inside a *write* transaction; doing it in a RO
/// txn returns `EACCES` (13) = "Permission denied". Because the `memory`
/// DB did not yet exist in `~/.arc/global`, the very first chat message
/// crashed the whole session agent with "LMDB error 13".
///
/// The fix: open the DB with `create: false` in the RO txn, and treat
/// `MDB_NOTFOUND` as "no memory yet" (empty string) rather than an error.
public struct LMDBMemoryProvider: MemoryProvider {

    private let queue: DispatchQueue
    private let globalPath: String
    private let globalEnv: LMDBEnvRef?

    /// Create a memory provider against the default global env
    /// (`~/.arc/global`), opened/closed per call.
    public init() {
        self.queue = DispatchQueue(label: "com.arc-agent.lmdb-memory", qos: .utility)
        self.globalPath = LMDBManager.globalPath
        self.globalEnv = nil
    }

    /// Create a memory provider against a custom global env path
    /// (transient open/close per call). Useful for tests and alternate
    /// storage locations.
    public init(globalPath: String) {
        self.queue = DispatchQueue(label: "com.arc-agent.lmdb-memory", qos: .utility)
        self.globalPath = globalPath
        self.globalEnv = nil
    }

    /// Create a memory provider wrapping a pre-opened global env.
    /// The environment is NOT closed on deinit — the caller owns it.
    public init(globalEnv: OpaquePointer, globalPath: String = LMDBManager.globalPath) {
        self.queue = DispatchQueue(label: "com.arc-agent.lmdb-memory", qos: .utility)
        self.globalPath = globalPath
        self.globalEnv = LMDBEnvRef(globalEnv)
    }

    // MARK: - MemoryProvider

    public func readMemory() async throws -> String {
        try await read(key: "agent")
    }

    public func readUser() async throws -> String {
        try await read(key: "user")
    }

    public func appendMemory(_ text: String) async throws {
        try await append(key: "agent", text: text)
    }

    public func replaceMemory(old: String, new: String) async throws {
        try await replace(key: "agent", old: old, new: new)
    }

    public func writeMemory(_ text: String) async throws {
        try await set(key: "agent", value: text)
    }

    public func appendUser(_ text: String) async throws {
        try await append(key: "user", text: text)
    }

    public func replaceUser(old: String, new: String) async throws {
        try await replace(key: "user", old: old, new: new)
    }

    // MARK: - Private

    /// Run an operation against the global env. Uses the pre-opened env if
    /// available; otherwise opens a fresh one for the duration and closes it.
    private func withGlobalEnv<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        if let ref = globalEnv {
            return try operation(ref.env)
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: globalPath),
            withIntermediateDirectories: true
        )
        let env = try LMDB.envOpen(
            path: globalPath, mapSize: 100 * 1024 * 1024,
            maxReaders: 64, maxDBs: 16, flags: 0
        )
        defer { LMDB.envClose(env) }
        return try operation(env)
    }

    private func read(key: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    // Transient mode: a missing global dir means no memory yet.
                    if self.globalEnv == nil,
                       !FileManager.default.fileExists(atPath: self.globalPath) {
                        continuation.resume(returning: "")
                        return
                    }
                    let content = try self.withGlobalEnv { env in
                        let txn = try LMDB.txnBeginRead(env: env)
                        defer { LMDB.txnAbort(txn) }

                        // FIX: create:false. The memory DB may not exist yet;
                        // creating it in a RO txn is illegal (EACCES). A missing
                        // DB is simply "no memory yet".
                        let dbi: UInt32
                        do {
                            dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "memory", create: false)
                        } catch let e as LMDBError where e.rc == MDB_NOTFOUND {
                            return ""
                        }

                        guard let value = try LMDB.get(env: env, txn: txn, dbi: dbi, key: [UInt8](key.utf8)) else {
                            return ""
                        }
                        return String(decoding: value, as: UTF8.self)
                    }
                    continuation.resume(returning: content)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func append(key: String, text: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.withGlobalEnv { env in
                        let txn = try LMDB.txnBeginWrite(env: env)
                        var committed = false
                        defer { if !committed { LMDB.txnAbort(txn) } }

                        let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "memory", create: true)
                        let keyBytes = [UInt8](key.utf8)

                        let existing: String
                        if let bytes = try LMDB.get(env: env, txn: txn, dbi: dbi, key: keyBytes) {
                            existing = String(decoding: bytes, as: UTF8.self)
                        } else {
                            existing = ""
                        }

                        let newContent = existing.isEmpty ? text : existing + "\n" + text
                        try LMDB.set(env: env, txn: txn, dbi: dbi, key: keyBytes, value: [UInt8](newContent.utf8))
                        try LMDB.txnCommit(txn)
                        committed = true
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Overwrite a key with the given value.
    private func set(key: String, value: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.withGlobalEnv { env in
                        let txn = try LMDB.txnBeginWrite(env: env)
                        var committed = false
                        defer { if !committed { LMDB.txnAbort(txn) } }

                        let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "memory", create: true)
                        try LMDB.set(env: env, txn: txn, dbi: dbi, key: [UInt8](key.utf8), value: [UInt8](value.utf8))
                        try LMDB.txnCommit(txn)
                        committed = true
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func replace(key: String, old: String, new: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.withGlobalEnv { env in
                        let txn = try LMDB.txnBeginWrite(env: env)
                        var committed = false
                        defer { if !committed { LMDB.txnAbort(txn) } }

                        let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "memory", create: true)
                        let keyBytes = [UInt8](key.utf8)

                        guard let bytes = try LMDB.get(env: env, txn: txn, dbi: dbi, key: keyBytes) else {
                            return
                        }

                        var content = String(decoding: bytes, as: UTF8.self)
                        content = content.replacingOccurrences(of: old, with: new)
                        try LMDB.set(env: env, txn: txn, dbi: dbi, key: keyBytes, value: [UInt8](content.utf8))
                        try LMDB.txnCommit(txn)
                        committed = true
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
