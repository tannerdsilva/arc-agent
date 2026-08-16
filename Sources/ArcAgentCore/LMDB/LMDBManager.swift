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
        baseURL.appendingPathComponent("global.mdb").path
    }()

    public static let sessionsDir: String = {
        baseURL.appendingPathComponent("sessions", isDirectory: true).path
    }()

    public static func sessionPath(_ id: String) -> String {
        "\(sessionsDir)/\(id).mdb"
    }

    /// Open the global environment.
    public static func openGlobal() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return try LMDB.envOpen(path: globalPath, mapSize: 100 * 1024 * 1024, maxReaders: 64, maxDBs: 16)
    }

    /// Open a per-session environment.
    public static func openSession(_ id: String) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: sessionsDir), withIntermediateDirectories: true)
        return try LMDB.envOpen(path: sessionPath(id), mapSize: 50 * 1024 * 1024, maxReaders: 8, maxDBs: 8)
    }
}
