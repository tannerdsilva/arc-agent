import Testing
@testable import ArcAgentCore
import Foundation
import CLMDB

// =========================================================================
// MARK: - LMDB Fault Injection (Phase D)

@Suite("LMDB Fault Injection")
struct LMDBFaultInjectionTests {

    /// Open a temp env + store that owns a persistent environment.
    private func makeStore() throws -> (env: OpaquePointer, store: LMDBSessionStore, sessionID: String, tmp: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmdb-fault-\(UUID().uuidString)")
        let sessionID = UUID().uuidString
        let dir = tmp.appendingPathComponent(sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = try LMDB.envOpen(
            path: dir.appendingPathComponent("session.mdb").path,
            mapSize: 10 * 1024 * 1024,
            maxReaders: 4,
            maxDBs: 8,
            flags: 0
        )
        let store = LMDBSessionStore(envBits: envHandleBits(env))
        return (env, store, sessionID, tmp)
    }

    /// Seed a valid session with one user message; returns the stored key.
    private func seedValidSession(_ env: OpaquePointer, store: LMDBSessionStore, sessionID: String) async throws {
        let session = Session(
            id: sessionID,
            model: "m",
            provider: "p",
            messages: [Message(role: .user, content: "hello")]
        )
        try await store.create(session)
    }

    @Test("corrupt message header throws a clean storage error instead of trapping")
    func corruptHeaderFailsCleanly() async throws {
        let (env, store, sessionID, tmp) = try makeStore()
        defer {
            LMDB.envClose(env)
            try? FileManager.default.removeItem(at: tmp)
        }
        try await seedValidSession(env, store: store, sessionID: sessionID)

        // Overwrite the fixed-size header with a 5-byte blob. The reader must
        // surface a storage error, not an out-of-bounds crash on the slice.
        let txn = try LMDB.txnBeginWrite(env: env)
        var committed = false
        defer { if !committed { LMDB.txnAbort(txn) } }
        let headers = try LMDB.dbiOpen(env: env, txn: txn, name: "headers", create: false)
        try LMDB.set(env: env, txn: txn, dbi: headers, key: LMDBManager.seqKey(0), value: [1, 2, 3, 4, 5])
        try LMDB.txnCommit(txn)
        committed = true

        do {
            _ = try await store.get(id: sessionID)
            Issue.record("expected corrupt header to throw")
        } catch let e as SessionError {
            #expect(e.description.contains("corrupt message header"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("missing message body throws a clean storage error")
    func missingBodyFailsCleanly() async throws {
        let (env, store, sessionID, tmp) = try makeStore()
        defer {
            LMDB.envClose(env)
            try? FileManager.default.removeItem(at: tmp)
        }
        try await seedValidSession(env, store: store, sessionID: sessionID)

        // Delete the body while leaving the header intact.
        let txn = try LMDB.txnBeginWrite(env: env)
        var committed = false
        defer { if !committed { LMDB.txnAbort(txn) } }
        let bodies = try LMDB.dbiOpen(env: env, txn: txn, name: "bodies", create: false)
        try LMDB.del(env: env, txn: txn, dbi: bodies, key: LMDBManager.seqKey(0))
        try LMDB.txnCommit(txn)
        committed = true

        do {
            _ = try await store.get(id: sessionID)
            Issue.record("expected missing body to throw")
        } catch let e as SessionError {
            #expect(e.description.contains("missing message body"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("corrupt meta JSON throws instead of trapping")
    func corruptMetaFailsCleanly() async throws {
        let (env, store, sessionID, tmp) = try makeStore()
        defer {
            LMDB.envClose(env)
            try? FileManager.default.removeItem(at: tmp)
        }
        try await seedValidSession(env, store: store, sessionID: sessionID)

        // Replace the metadata blob with non-JSON garbage.
        let txn = try LMDB.txnBeginWrite(env: env)
        var committed = false
        defer { if !committed { LMDB.txnAbort(txn) } }
        let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: false)
        try LMDB.set(env: env, txn: txn, dbi: meta,
            key: [UInt8]("session_meta".utf8),
            value: [UInt8]("this is not json".utf8))
        try LMDB.txnCommit(txn)
        committed = true

        // Any thrown error is acceptable here — the point is a clean throw,
        // never a trap or crash.
        do {
            _ = try await store.get(id: sessionID)
            Issue.record("expected corrupt metadata to throw")
        } catch {
            // clean failure
        }
    }

    @Test("corrupted data can be repaired and reads resume")
    func corruptionIsRepairable() async throws {
        let (env, store, sessionID, tmp) = try makeStore()
        defer {
            LMDB.envClose(env)
            try? FileManager.default.removeItem(at: tmp)
        }
        try await seedValidSession(env, store: store, sessionID: sessionID)

        // Corrupt seq 0's header → the read must fail cleanly.
        do {
            let txn = try LMDB.txnBeginWrite(env: env)
            var committed = false
            defer { if !committed { LMDB.txnAbort(txn) } }
            let headers = try LMDB.dbiOpen(env: env, txn: txn, name: "headers", create: false)
            try LMDB.set(env: env, txn: txn, dbi: headers, key: LMDBManager.seqKey(0), value: [7, 7, 7])
            try LMDB.txnCommit(txn)
            committed = true
        }
        do {
            _ = try await store.get(id: sessionID)
            Issue.record("expected corrupt header to throw")
        } catch is SessionError {
            // clean failure
        }

        // Repair with a well-formed header+body pair; the store must read it
        // back — corruption must not wedge the session.
        let msg = Message(role: .user, content: "hello")
        let bodyData = try JSONEncoder().encode(msg)
        let header = MessageHeader(role: 1, timestamp: 0, bodyLength: UInt32(bodyData.count))

        let txn = try LMDB.txnBeginWrite(env: env)
        var committed = false
        defer { if !committed { LMDB.txnAbort(txn) } }
        let headers = try LMDB.dbiOpen(env: env, txn: txn, name: "headers", create: false)
        let bodies = try LMDB.dbiOpen(env: env, txn: txn, name: "bodies", create: false)
        try LMDB.set(env: env, txn: txn, dbi: headers, key: LMDBManager.seqKey(0), value: header.bytes)
        try LMDB.set(env: env, txn: txn, dbi: bodies, key: LMDBManager.seqKey(0), value: [UInt8](bodyData))
        try LMDB.txnCommit(txn)
        committed = true

        let loaded = try await store.get(id: sessionID)
        #expect(loaded?.messages.count == 1)
        #expect(loaded?.messages.first?.content == "hello")
    }
}
