import Foundation

/// Manages LMDB environments for ARC Agent.
///
/// **Global environment** (`~/.arc/global.mdb`):
/// - `memory` database: user profile + agent memory
///
/// **Per-session environments** (`~/.arc/sessions/<id>.mdb`):
/// - `meta` database: session metadata
/// - `messages` database: ordered message history
public enum LMDBManager: Sendable {

    public static let baseURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc", isDirectory: true)
    }()

    public static let globalPath: String = {
        baseURL.appendingPathComponent("global", isDirectory: true).path
    }()

    public static let sessionsDir: String = {
        baseURL.appendingPathComponent("sessions", isDirectory: true).path
    }()

    /// Profile storage paths.
    public static let profilesDir: String = {
        baseURL.appendingPathComponent("profiles", isDirectory: true).path
    }()

    public static func profileMemoryPath(_ name: String) -> String {
        "\(profilesDir)/\(name)/memory.mdb"
    }

    public static func profileSessionsDir(_ name: String) -> String {
        "\(profilesDir)/\(name)/sessions"
    }

    public static func profileSessionPath(_ name: String, id: String) -> String {
        "\(profileSessionsDir(name))/\(id).mdb"
    }

    public static func sessionPath(_ id: String) -> String {
        "\(sessionsDir)/\(id)"
    }

    /// Encode a UInt64 as big-endian bytes for use as an LMDB key.
    /// Big-endian encoding ensures numeric order = lexicographic order.
    public static func seqKey(_ seq: UInt64) -> [UInt8] {
        var be = seq.bigEndian
        return Swift.withUnsafeBytes(of: &be) { [UInt8]($0) }
    }

    /// Decode a UInt64 from big-endian bytes.
    public static func seqFromKey(_ key: [UInt8]) -> UInt64 {
        assert(key.count == 8, "seq key must be exactly 8 bytes")
        var val: UInt64 = 0
        withUnsafeMutableBytes(of: &val) { dest in
            dest.copyBytes(from: key)
        }
        return UInt64(bigEndian: val)
    }

    /// Open a per-session environment.
    public static func openSession(_ id: String) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: sessionsDir), withIntermediateDirectories: true)
        let dir = sessionPath(id)
        // Directory may already exist from a previous session — that's fine
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            // Directory already exists — that's fine
        }
        return try LMDB.envOpen(path: dir, mapSize: 50 * 1024 * 1024, maxReaders: 8, maxDBs: 8, flags: 0)
    }
}

// MARK: - Global Environment (process singleton)

/// The process-wide shared environment for the global `.mdb`
/// (`~/.arc/global`), owned by a single actor so every component (profile
/// store, memory provider) uses exactly one environment handle.
///
/// The global DB is a process singleton by design (VISION: "Memory System
/// [1 — shared global .mdb]"). Opening and closing the same path per call
/// from concurrent tasks races on LMDB's exclusive semaphore and fails with
/// `EEXIST` (17) — two session agents reading memory at once collided. The
/// handle is opened lazily once, reused for the process lifetime, and closed
/// via ``close()`` at gateway teardown.
actor GlobalEnvironment {

    /// The shared instance.
    static let shared = GlobalEnvironment()

    private var env: OpaquePointer?

    /// Run an operation against the shared global environment.
    ///
    /// Executes on this actor's executor, so the raw handle never crosses an
    /// isolation boundary. The closure is `sending`: it must capture only
    /// Sendable values.
    func withOpenEnv<T: Sendable>(_ op: sending (OpaquePointer) throws -> T) async throws -> T {
        if env == nil {
            try FileManager.default.createDirectory(at: LMDBManager.baseURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: LMDBManager.globalPath),
                withIntermediateDirectories: true
            )
            env = try LMDB.envOpen(
                path: LMDBManager.globalPath, mapSize: 100 * 1024 * 1024,
                maxReaders: 64, maxDBs: 16, flags: 0
            )
        }
        guard let env else {
            throw LMDBError(rc: -1)
        }
        return try op(env)
    }

    /// Close the shared environment. Called at gateway teardown; the handle
    /// is reopened lazily if anything touches it afterwards.
    func close() {
        if let env { LMDB.envClose(env) }
        env = nil
    }
}
