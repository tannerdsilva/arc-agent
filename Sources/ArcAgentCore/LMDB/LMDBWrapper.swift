import Foundation
import CLMDB

/// A thin, Sendable wrapper around the LMDB C API.
///
/// This replaces QuickLMDB v14 which uses non-copyable types incompatible
/// with async Swift. The wrapper exposes only what ARC Agent needs:
/// environment management, key-value get/put/delete, and transactions.
///
/// All operations are synchronous and designed to be called from
/// `withCheckedThrowingContinuation` on a GCD queue.
public enum LMDB: Sendable {

    // MARK: - Environment

    /// Open or create an LMDB environment.
    public static func envOpen(path: String, mapSize: Int, maxReaders: UInt32, maxDBs: UInt32, flags: UInt32 = UInt32(MDB_NOSUBDIR)) throws -> OpaquePointer {
        var env: OpaquePointer?
        var rc = mdb_env_create(&env)
        guard rc == 0 else { throw LMDBError(rc: rc) }

        rc = mdb_env_set_mapsize(env, mapSize)
        guard rc == 0 else { mdb_env_close(env); throw LMDBError(rc: rc) }

        rc = mdb_env_set_maxreaders(env, maxReaders)
        guard rc == 0 else { mdb_env_close(env); throw LMDBError(rc: rc) }

        rc = mdb_env_set_maxdbs(env, maxDBs)
        guard rc == 0 else { mdb_env_close(env); throw LMDBError(rc: rc) }

        rc = mdb_env_open(env, path, flags, 0o644)
        guard rc == 0 else { mdb_env_close(env); throw LMDBError(rc: rc) }

        return env!
    }

    /// Close an LMDB environment.
    public static func envClose(_ env: OpaquePointer?) {
        mdb_env_close(env)
    }

    // MARK: - Transaction

    /// Begin a read-only transaction.
    public static func txnBeginRead(env: OpaquePointer) throws -> OpaquePointer {
        var txn: OpaquePointer?
        let rc = mdb_txn_begin(env, nil, UInt32(MDB_RDONLY), &txn)
        guard rc == 0 else { throw LMDBError(rc: rc) }
        return txn!
    }

    /// Begin a read-write transaction.
    public static func txnBeginWrite(env: OpaquePointer) throws -> OpaquePointer {
        var txn: OpaquePointer?
        let rc = mdb_txn_begin(env, nil, UInt32(0), &txn)
        guard rc == 0 else { throw LMDBError(rc: rc) }
        return txn!
    }

    /// Commit a transaction.
    public static func txnCommit(_ txn: OpaquePointer?) throws {
        let rc = mdb_txn_commit(txn)
        guard rc == 0 else { throw LMDBError(rc: rc) }
    }

    /// Abort a transaction.
    public static func txnAbort(_ txn: OpaquePointer?) {
        mdb_txn_abort(txn)
    }

    // MARK: - Database Handle

    /// Open a named database within an environment.
    public static func dbiOpen(env: OpaquePointer, txn: OpaquePointer, name: String?, create: Bool) throws -> UInt32 {
        var dbi: UInt32 = 0
        let flags: UInt32 = create ? UInt32(MDB_CREATE) : 0
        let rc = mdb_dbi_open(txn, name, flags, &dbi)
        guard rc == 0 else { throw LMDBError(rc: rc) }
        return dbi
    }

    // MARK: - Key-Value Operations

    /// Get a value by key. Returns nil if the key doesn't exist.
    public static func get(env: OpaquePointer, txn: OpaquePointer, dbi: UInt32, key: [UInt8]) throws -> [UInt8]? {
        var keyCopy = key
        var keyVal = MDB_val(mv_size: keyCopy.count, mv_data: &keyCopy)
        var valVal = MDB_val(mv_size: 0, mv_data: nil)

        let rc = mdb_get(txn, dbi, &keyVal, &valVal)
        if rc == MDB_NOTFOUND { return nil }
        guard rc == 0 else { throw LMDBError(rc: rc) }

        let data = Data(bytes: valVal.mv_data, count: valVal.mv_size)
        return [UInt8](data)
    }

    /// Set a key-value pair.
    public static func set(env: OpaquePointer, txn: OpaquePointer, dbi: UInt32, key: [UInt8], value: [UInt8]) throws {
        var keyCopy = key
        var valCopy = value
        var keyVal = MDB_val(mv_size: keyCopy.count, mv_data: &keyCopy)
        var valVal = MDB_val(mv_size: valCopy.count, mv_data: &valCopy)

        let rc = mdb_put(txn, dbi, &keyVal, &valVal, 0)
        guard rc == 0 else { throw LMDBError(rc: rc) }
    }

    /// Delete a key-value pair.
    public static func del(env: OpaquePointer, txn: OpaquePointer, dbi: UInt32, key: [UInt8]) throws {
        var keyCopy = key
        var keyVal = MDB_val(mv_size: keyCopy.count, mv_data: &keyCopy)
        let rc = mdb_del(txn, dbi, &keyVal, nil)
        guard rc == 0 || rc == MDB_NOTFOUND else { throw LMDBError(rc: rc) }
    }

    /// Clear all entries from a database.
    public static func clear(env: OpaquePointer, txn: OpaquePointer, dbi: UInt32) throws {
        let rc = mdb_drop(txn, dbi, 1)
        guard rc == 0 else { throw LMDBError(rc: rc) }
    }

    /// Check if a key exists.
    public static func exists(env: OpaquePointer, txn: OpaquePointer, dbi: UInt32, key: [UInt8]) throws -> Bool {
        var keyCopy = key
        var keyVal = MDB_val(mv_size: keyCopy.count, mv_data: &keyCopy)
        var valVal = MDB_val(mv_size: 0, mv_data: nil)
        let rc = mdb_get(txn, dbi, &keyVal, &valVal)
        if rc == MDB_NOTFOUND { return false }
        guard rc == 0 else { throw LMDBError(rc: rc) }
        return true
    }

    // MARK: - Cursor

    /// Open a cursor for iterating over a database.
    public static func cursorOpen(txn: OpaquePointer, dbi: UInt32) throws -> OpaquePointer {
        var cursor: OpaquePointer?
        let rc = mdb_cursor_open(txn, dbi, &cursor)
        guard rc == 0 else { throw LMDBError(rc: rc) }
        return cursor!
    }

    /// Close a cursor.
    public static func cursorClose(_ cursor: OpaquePointer?) {
        mdb_cursor_close(cursor)
    }

    /// Position the cursor at the first key >= the given key.
    /// Returns (key, value) or nil if no such key exists.
    public static func cursorSetRange(cursor: OpaquePointer, key: [UInt8]) throws -> ([UInt8], [UInt8])? {
        var keyCopy = key
        var keyVal = MDB_val(mv_size: keyCopy.count, mv_data: &keyCopy)
        var valVal = MDB_val(mv_size: 0, mv_data: nil)
        let rc = mdb_cursor_get(cursor, &keyVal, &valVal, MDB_SET_RANGE)
        if rc == MDB_NOTFOUND { return nil }
        guard rc == 0 else { throw LMDBError(rc: rc) }
        let k = Data(bytes: keyVal.mv_data, count: keyVal.mv_size)
        let v = Data(bytes: valVal.mv_data, count: valVal.mv_size)
        return ([UInt8](k), [UInt8](v))
    }

    /// Move to the next entry. Returns (key, value) or nil at end.
    public static func cursorNext(cursor: OpaquePointer) throws -> ([UInt8], [UInt8])? {
        var keyVal = MDB_val(mv_size: 0, mv_data: nil)
        var valVal = MDB_val(mv_size: 0, mv_data: nil)
        let rc = mdb_cursor_get(cursor, &keyVal, &valVal, MDB_NEXT)
        if rc == MDB_NOTFOUND { return nil }
        guard rc == 0 else { throw LMDBError(rc: rc) }
        let k = Data(bytes: keyVal.mv_data, count: keyVal.mv_size)
        let v = Data(bytes: valVal.mv_data, count: valVal.mv_size)
        return ([UInt8](k), [UInt8](v))
    }

    /// Move to the last entry. Returns (key, value) or nil if empty.
    public static func cursorLast(cursor: OpaquePointer) throws -> ([UInt8], [UInt8])? {
        var keyVal = MDB_val(mv_size: 0, mv_data: nil)
        var valVal = MDB_val(mv_size: 0, mv_data: nil)
        let rc = mdb_cursor_get(cursor, &keyVal, &valVal, MDB_LAST)
        if rc == MDB_NOTFOUND { return nil }
        guard rc == 0 else { throw LMDBError(rc: rc) }
        let k = Data(bytes: keyVal.mv_data, count: keyVal.mv_size)
        let v = Data(bytes: valVal.mv_data, count: valVal.mv_size)
        return ([UInt8](k), [UInt8](v))
    }

    /// Move to the previous entry. Returns (key, value) or nil at start.
    public static func cursorPrev(cursor: OpaquePointer) throws -> ([UInt8], [UInt8])? {
        var keyVal = MDB_val(mv_size: 0, mv_data: nil)
        var valVal = MDB_val(mv_size: 0, mv_data: nil)
        let rc = mdb_cursor_get(cursor, &keyVal, &valVal, MDB_PREV)
        if rc == MDB_NOTFOUND { return nil }
        guard rc == 0 else { throw LMDBError(rc: rc) }
        let k = Data(bytes: keyVal.mv_data, count: keyVal.mv_size)
        let v = Data(bytes: valVal.mv_data, count: valVal.mv_size)
        return ([UInt8](k), [UInt8](v))
    }

    /// Read the current cursor position without moving. Returns (key, value).
    public static func cursorCurrent(cursor: OpaquePointer) throws -> ([UInt8], [UInt8]) {
        var keyVal = MDB_val(mv_size: 0, mv_data: nil)
        var valVal = MDB_val(mv_size: 0, mv_data: nil)
        let rc = mdb_cursor_get(cursor, &keyVal, &valVal, MDB_GET_CURRENT)
        guard rc == 0 else { throw LMDBError(rc: rc) }
        let k = Data(bytes: keyVal.mv_data, count: keyVal.mv_size)
        let v = Data(bytes: valVal.mv_data, count: valVal.mv_size)
        return ([UInt8](k), [UInt8](v))
    }
}

// MARK: - Error

public struct LMDBError: Error, Sendable, CustomStringConvertible {
    public let rc: Int32
    public let message: String

    public init(rc: Int32) {
        self.rc = rc
        self.message = String(cString: mdb_strerror(rc))
    }

    public var description: String {
        "LMDB error \(rc): \(message)"
    }
}
