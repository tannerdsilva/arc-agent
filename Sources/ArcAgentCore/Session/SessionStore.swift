import Foundation

/// A session represents a single conversation with the agent.
public struct Session: Sendable, Codable {
    /// Unique session identifier.
    public let id: String
    /// When the session was created.
    public let createdAt: Date
    /// When the session was last updated.
    public var updatedAt: Date
    /// The model used for this session.
    public var model: String
    /// The provider used for this session.
    public var provider: String
    /// Messages in this session.
    public var messages: [Message]

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        model: String = "",
        provider: String = "",
        messages: [Message] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.provider = provider
        self.messages = messages
    }
}

/// A store for persisting and retrieving sessions.
///
/// ## Design (Protocols First)
///
/// 1. **Protocol** — ``SessionStore`` (this protocol)
/// 2. **Concrete types** — ``FileSessionStore``, future ``LMDBSessionStore``
/// 3. **Macros** — None needed
///
/// The protocol is intentionally minimal. The LMDB-backed implementation from
/// VISION.md will add composite key scans and full-text search, but those are
/// optimizations, not API changes.
public protocol SessionStore: Sendable {

    /// Create a new session.
    func create(_ session: Session) async throws

    /// Retrieve a session by ID.
    func get(id: String) async throws -> Session?

    /// Update an existing session.
    func update(_ session: Session) async throws

    /// Delete a session.
    func delete(id: String) async throws

    /// List all sessions, newest first.
    func list(limit: Int) async throws -> [Session]

    /// Append a message to a session.
    func appendMessage(sessionID: String, message: Message) async throws
}

/// A file-based session store that persists sessions as JSON files.
///
/// Each session is stored as a separate JSON file under the sessions directory.
/// This is a temporary implementation — the LMDB-backed store from VISION.md
/// will replace it once QuickLMDB is added as a dependency.
///
/// ## File Layout
/// ```
/// ~/.arc/sessions/
/// ├── <session-id>.json
/// └── ...
/// ```
public struct FileSessionStore: SessionStore {

    /// The directory where session files are stored.
    public let directory: URL

    /// Create a file-based session store.
    ///
    /// - Parameter directory: The directory for session files.
    ///   Defaults to `~/.arc/sessions/`.
    public init(directory: URL? = nil) {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/sessions")
        self.directory = directory ?? defaultDir
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - SessionStore

    public func create(_ session: Session) async throws {
        let url = fileURL(for: session.id)
        let data = try JSONEncoder().encode(session)
        try data.write(to: url, options: .atomic)
    }

    public func get(id: String) async throws -> Session? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Session.self, from: data)
    }

    public func update(_ session: Session) async throws {
        var updated = session
        updated.updatedAt = Date()
        try await create(updated)
    }

    public func delete(id: String) async throws {
        let url = fileURL(for: id)
        try FileManager.default.removeItem(at: url)
    }

    public func list(limit: Int) async throws -> [Session] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA > dateB
        }
        .prefix(limit)

        var sessions: [Session] = []
        for file in files {
            let data = try Data(contentsOf: file)
            if let session = try? JSONDecoder().decode(Session.self, from: data) {
                sessions.append(session)
            }
        }
        return sessions
    }

    public func appendMessage(sessionID: String, message: Message) async throws {
        guard var session = try await get(id: sessionID) else {
            throw SessionError.notFound(sessionID)
        }
        session.messages.append(message)
        try await update(session)
    }

    // MARK: - Helpers

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}

// MARK: - Errors

public enum SessionError: Error, Sendable, CustomStringConvertible {
    case notFound(String)
    case storageError(String)

    public var description: String {
        switch self {
        case .notFound(let id):
            return "Session '\(id)' not found."
        case .storageError(let message):
            return "Storage error: \(message)"
        }
    }
}
