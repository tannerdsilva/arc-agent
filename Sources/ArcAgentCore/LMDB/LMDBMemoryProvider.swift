import Foundation

/// An LMDB-backed memory provider using the raw LMDB C API.
public struct LMDBMemoryProvider: MemoryProvider {

    private let queue: DispatchQueue

    public init() {
        self.queue = DispatchQueue(label: "com.arc-agent.lmdb-memory", qos: .utility)
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

    public func appendUser(_ text: String) async throws {
        try await append(key: "user", text: text)
    }

    public func replaceUser(old: String, new: String) async throws {
        try await replace(key: "user", old: old, new: new)
    }

    // MARK: - Private

    private func read(key: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard FileManager.default.fileExists(atPath: LMDBManager.globalPath) else {
                        continuation.resume(returning: ""); return
                    }
                    let env = try LMDBManager.openGlobal()
                    defer { LMDB.envClose(env) }

                    let txn = try LMDB.txnBeginRead(env: env)
                    defer { LMDB.txnAbort(txn) }

                    let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "memory", create: false)
                    let keyBytes = [UInt8](key.utf8)

                    guard let value = try LMDB.get(env: env, txn: txn, dbi: dbi, key: keyBytes) else {
                        continuation.resume(returning: ""); return
                    }
                    continuation.resume(returning: String(decoding: value, as: UTF8.self))
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
                    let env = try LMDBManager.openGlobal()
                    defer { LMDB.envClose(env) }

                    let txn = try LMDB.txnBeginWrite(env: env)
                    defer { LMDB.txnAbort(txn) }

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
                    let env = try LMDBManager.openGlobal()
                    defer { LMDB.envClose(env) }

                    let txn = try LMDB.txnBeginWrite(env: env)
                    defer { LMDB.txnAbort(txn) }

                    let dbi = try LMDB.dbiOpen(env: env, txn: txn, name: "memory", create: true)
                    let keyBytes = [UInt8](key.utf8)

                    guard let bytes = try LMDB.get(env: env, txn: txn, dbi: dbi, key: keyBytes) else {
                        continuation.resume(); return
                    }

                    var content = String(decoding: bytes, as: UTF8.self)
                    content = content.replacingOccurrences(of: old, with: new)
                    try LMDB.set(env: env, txn: txn, dbi: dbi, key: keyBytes, value: [UInt8](content.utf8))
                    try LMDB.txnCommit(txn)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
