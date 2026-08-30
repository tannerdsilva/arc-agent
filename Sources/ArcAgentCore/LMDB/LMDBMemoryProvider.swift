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
///
/// ## Concurrency
///
/// ``LMDBMemoryProvider`` is an **actor**. Every LMDB operation runs directly
/// on the actor's executor — no dispatch queues and no continuation bridging.
/// The environment pointer lives in actor-isolated state, so no `@unchecked
/// Sendable` wrapper is needed.
public actor LMDBMemoryProvider: MemoryProvider {

    private let globalPath: String
    private let globalEnv: OpaquePointer?

    /// Create a memory provider against the default global env
    /// (`~/.arc/global`), opened/closed per call.
    public init() {
        self.globalPath = LMDBManager.globalPath
        self.globalEnv = nil
    }

    /// Create a memory provider against a custom global env path
    /// (transient open/close per call). Useful for tests and alternate
    /// storage locations.
    public init(globalPath: String) {
        self.globalPath = globalPath
        self.globalEnv = nil
    }

    /// Create a memory provider wrapping a pre-opened global env.
    /// The environment is NOT closed by the provider — the caller owns it.
    /// - Parameter globalEnvBits: Bit pattern of a pre-opened environment.
    ///
    /// An `OpaquePointer` is not `Sendable`, so the handle crosses the actor
    /// boundary as its bit pattern (`UInt` is `Sendable`) and is reconstructed
    /// here, where it lives in isolated state and is never shared.
    public init(globalEnvBits: UInt, globalPath: String = LMDBManager.globalPath) {
        self.globalPath = globalPath
        self.globalEnv = UnsafeRawPointer(bitPattern: globalEnvBits).map(OpaquePointer.init)
    }

    // MARK: - MemoryProvider

    public func readMemory() async throws -> String {
        try read(key: "agent")
    }

    public func readUser() async throws -> String {
        try read(key: "user")
    }

    public func appendMemory(_ text: String) async throws {
        try append(key: "agent", text: text)
    }

    public func replaceMemory(old: String, new: String) async throws {
        try replace(key: "agent", old: old, new: new)
    }

    public func writeMemory(_ text: String) async throws {
        try set(key: "agent", value: text)
    }

    public func appendUser(_ text: String) async throws {
        try append(key: "user", text: text)
    }

    public func replaceUser(old: String, new: String) async throws {
        try replace(key: "user", old: old, new: new)
    }

    // MARK: - Private

    /// Run an operation against the global env. Uses the pre-opened env if
    /// available; otherwise opens a fresh one for the duration and closes it.
    /// Runs directly on the actor's executor (never on a dispatch queue).
    private func withGlobalEnv<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        if let ref = globalEnv {
            return try operation(ref)
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

    private func read(key: String) throws -> String {
        // Transient mode: a missing global dir means no memory yet.
        if globalEnv == nil,
           !FileManager.default.fileExists(atPath: globalPath) {
            return ""
        }
        return try withGlobalEnv { env in
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
    }

    private func append(key: String, text: String) throws {
        try withGlobalEnv { env in
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
    }

    /// Overwrite a key with the given value.
    private func set(key: String, value: String) throws {
        try withGlobalEnv { env in
            let txn = try LMDB.txnBeginWrite(env: env)
            var committed = false
            defer { if !committed { LMDB.txnAbort(txn) } }

            let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "memory", create: true)
            try LMDB.set(env: env, txn: txn, dbi: dbi, key: [UInt8](key.utf8), value: [UInt8](value.utf8))
            try LMDB.txnCommit(txn)
            committed = true
        }
    }

    private func replace(key: String, old: String, new: String) throws {
        try withGlobalEnv { env in
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
    }
}
