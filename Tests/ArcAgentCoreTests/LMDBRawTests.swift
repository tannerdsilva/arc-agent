import Testing
@testable import ArcAgentCore
import Foundation
import CLMDB

// =========================================================================
// MARK: - LMDB Raw Operations Tests
// =========================================================================

@Test("LMDB named databases with directory-based")
func lmdbNamedDbs() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-named-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let env = try LMDB.envOpen(path: tmp, mapSize: 10 * 1024 * 1024, maxReaders: 4, maxDBs: 8, flags: 0)
    defer { LMDB.envClose(env) }

    let txn = try LMDB.txnBeginWrite(env: env)
    let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: true)
    try LMDB.set(env: env, txn: txn, dbi: meta, key: [UInt8]("key".utf8), value: [UInt8]("value".utf8))
    try LMDB.txnCommit(txn)

    let txn2 = try LMDB.txnBeginRead(env: env)
    let meta2 = try LMDB.dbiOpen(env: env, txn: txn2, name: "meta", create: false)
    let val = try LMDB.get(env: env, txn: txn2, dbi: meta2, key: [UInt8]("key".utf8))
    LMDB.txnAbort(txn2)

    #expect(val != nil)
    #expect(String(data: Data(val!), encoding: .utf8) == "value")
}

@Test("creating a DB inside a read-only transaction fails with EACCES")
func lmdbCreateInReadonlyTxnFails() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-ro-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let env = try LMDB.envOpen(path: tmp, mapSize: 10 * 1024 * 1024, maxReaders: 4, maxDBs: 8, flags: 0)
    defer { LMDB.envClose(env) }

    // No DB exists yet. Opening a RO transaction and trying to CREATE a
    // named DB must fail — LMDB only permits creation in write txns.
    // The specific error is EACCES (13) = "Permission denied".
    let txn = try LMDB.txnBeginRead(env: env)
    defer { LMDB.txnAbort(txn) }

    do {
        _ = try LMDB.dbiOpen(env: env, txn: txn, name: "memory", create: true)
        #expect(false, "expected dbiOpen(create:true) in a RO txn to throw")
    } catch let e as LMDBError {
        #expect(e.rc == 13, "expected EACCES (13), got \(e.rc): \(e.message)")
    }
}

@Test("open existing DB in read-only transaction with create:false succeeds")
func lmdbOpenExistingInReadonlyTxn() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-ro2-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let env = try LMDB.envOpen(path: tmp, mapSize: 10 * 1024 * 1024, maxReaders: 4, maxDBs: 8, flags: 0)
    defer { LMDB.envClose(env) }

    // Seed the DB in a write txn.
    let wtxn = try LMDB.txnBeginWrite(env: env)
    let dbi = try LMDB.dbiOpen(env: env, txn: wtxn, name: "memory", create: true)
    try LMDB.set(env: env, txn: wtxn, dbi: dbi, key: [UInt8]("agent".utf8), value: [UInt8]("hello".utf8))
    try LMDB.txnCommit(wtxn)

    // Now read it back in an RO txn with create:false — must succeed.
    let rtxn = try LMDB.txnBeginRead(env: env)
    defer { LMDB.txnAbort(rtxn) }
    let dbi2 = try LMDB.dbiOpen(env: env, txn: rtxn, name: "memory", create: false)
    let val = try LMDB.get(env: env, txn: rtxn, dbi: dbi2, key: [UInt8]("agent".utf8))
    #expect(val != nil)
    #expect(String(data: Data(val!), encoding: .utf8) == "hello")
}

@Test("open missing DB in read-only transaction with create:false throws NOTFOUND")
func lmdbOpenMissingInReadonlyTxn() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-ro3-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let env = try LMDB.envOpen(path: tmp, mapSize: 10 * 1024 * 1024, maxReaders: 4, maxDBs: 8, flags: 0)
    defer { LMDB.envClose(env) }

    let txn = try LMDB.txnBeginRead(env: env)
    defer { LMDB.txnAbort(txn) }

    do {
        _ = try LMDB.dbiOpen(env: env, txn: txn, name: "memory", create: false)
        #expect(false, "expected dbiOpen(create:false) for a missing DB to throw NOTFOUND")
    } catch let e as LMDBError {
        #expect(e.rc == MDB_NOTFOUND)
    }
}

@Test("LMDB minimal session store create")
func lmdbMinimalCreate() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-min-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let env = try LMDB.envOpen(path: tmp, mapSize: 10 * 1024 * 1024, maxReaders: 4, maxDBs: 8, flags: 0)
    defer { LMDB.envClose(env) }

    // Open multiple databases WITH defer
    let txn = try LMDB.txnBeginWrite(env: env)
    defer { LMDB.txnAbort(txn) }
    let meta = try LMDB.dbiOpen(env: env, txn: txn, name: "meta", create: true)
    let headers = try LMDB.dbiOpen(env: env, txn: txn, name: "headers", create: true)
    let bodies = try LMDB.dbiOpen(env: env, txn: txn, name: "bodies", create: true)
    try LMDB.set(env: env, txn: txn, dbi: meta, key: [UInt8]("k".utf8), value: [UInt8]("v".utf8))
    try LMDB.set(env: env, txn: txn, dbi: headers, key: [UInt8]([0,0,0,0,0,0,0,1]), value: [UInt8]([1,2,3]))
    try LMDB.set(env: env, txn: txn, dbi: bodies, key: [UInt8]([0,0,0,0,0,0,0,1]), value: [UInt8]([4,5,6]))
    try LMDB.txnCommit(txn)
}
