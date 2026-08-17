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
        "\(sessionsDir)/\(id).mdb"
    }

    /// Encode a UInt64 as big-endian bytes for use as an LMDB key.
    /// Big-endian encoding ensures numeric order = lexicographic order.
    public static func seqKey(_ seq: UInt64) -> [UInt8] {
        var be = seq.bigEndian
        return withUnsafeBytes(of: &be) { [UInt8]($0) }
    }

    /// Decode a UInt64 from big-endian bytes.
    public static func seqFromKey(_ key: [UInt8]) -> UInt64 {
        assert(key.count == 8, "seq key must be exactly 8 bytes")
        return key.withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian
    }

    /// Open the global environment.
    public static func openGlobal() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        // Create the global environment directory
        let globalDir = baseURL.appendingPathComponent("global", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        // Use flags: 0 (directory-based environment) to support named databases
        return try LMDB.envOpen(path: globalPath, mapSize: 100 * 1024 * 1024, maxReaders: 64, maxDBs: 16, flags: 0)
    }

    /// Open a per-session environment.
    public static func openSession(_ id: String) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: sessionsDir), withIntermediateDirectories: true)
        return try LMDB.envOpen(path: sessionPath(id), mapSize: 50 * 1024 * 1024, maxReaders: 8, maxDBs: 8)
    }
}
