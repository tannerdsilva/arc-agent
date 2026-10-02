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
    /// Optional human-friendly title (background title generation).
    public var title: String?
    /// Messages in this session.
    ///
    /// For scalability, `list(limit:)` returns *summaries*: sessions whose
    /// `messages` array is empty. Message bodies are materialized on demand
    /// with `get(id:)` (the webui lazily loads a chat when it is opened and
    /// keeps a bounded LRU cache of loaded chats).
    public var messages: [Message]

    /// Number of messages known from metadata.
    ///
    /// Summaries carry this so UIs can show message counts (and excerpt
    /// hints) without materializing message bodies; `get(id:)` re-derives it
    /// from the loaded messages. Not persisted — always populated by the store.
    public var messageCount: Int = 0

    // MARK: - Reference session-standards fields (documented `sessions.md`)

    /// Source platform tag (`cli`, `telegram`, `slack`, `email`, …).
    public var source: String?
    /// Originating user identifier (per-platform id).
    public var userID: String?
    /// Parent session for compression-triggered lineage splits.
    public var parentSessionID: String?
    /// Workspace key (git repo root else cwd) — resume restores the cwd.
    public var workspaceKey: String?
    /// End timestamp (archived/ended sessions).
    public var endedAt: Date?
    /// Accumulated input tokens (reference token counts).
    public var inputTokens: Int?
    /// Accumulated output tokens (reference token counts).
    public var outputTokens: Int?
    /// Snapshot of the system prompt at session start.
    public var systemPrompt: String?

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, model, provider, title, messages
        case source, userID, parentSessionID, workspaceKey, endedAt
        case inputTokens, outputTokens, systemPrompt
    }

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        model: String = "",
        provider: String = "",
        title: String? = nil,
        messageCount: Int = 0,
        messages: [Message] = [],
        source: String? = nil,
        userID: String? = nil,
        parentSessionID: String? = nil,
        workspaceKey: String? = nil,
        endedAt: Date? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        systemPrompt: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.provider = provider
        self.title = title
        self.messageCount = messageCount
        self.messages = messages
        self.source = source
        self.userID = userID
        self.parentSessionID = parentSessionID
        self.workspaceKey = workspaceKey
        self.endedAt = endedAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.systemPrompt = systemPrompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        model = try c.decode(String.self, forKey: .model)
        provider = try c.decode(String.self, forKey: .provider)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        parentSessionID = try c.decodeIfPresent(String.self, forKey: .parentSessionID)
        workspaceKey = try c.decodeIfPresent(String.self, forKey: .workspaceKey)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        messageCount = 0  // re-derived by the store (never persisted)
    }
}

/// A store for persisting and retrieving sessions.
///
/// ## Design (Protocols First)
///
/// 1. **Protocol** — ``SessionStore`` (this protocol)
/// 2. **Concrete types** — ``FileSessionStore``, ``TesseraSessionStore``
/// 3. **Macros** — None needed
///
/// The protocol is intentionally minimal. The Tessera-backed implementation
/// stores sessions as signed NOSTR events; file storage and Tessera storage
/// expose the same API.
public protocol SessionStore: Sendable {

    /// Create a new session.
    func create(_ session: Session) async throws

    /// Retrieve a session by ID.
    func get(id: String) async throws -> Session?

    /// Update an existing session.
    func update(_ session: Session) async throws

    /// Delete a session.
    func delete(id: String) async throws

    /// List sessions, newest first, bounded at the store level.
    ///
    /// Returns *summaries only*: each session's `messages` array is empty and
    /// ``messageCount``/``title`` carry the metadata. Use `get(id:)` to
    /// materialize a session's messages. This keeps listing O(sessions) in
    /// memory and time instead of O(total messages).
    ///
    /// `limit` bounds how many summaries are returned **here** — the store
    /// never hands the UI more than `limit` sessions, and `offset` pages past
    /// the newest ones. The webui uses this for a bounded sidebar window plus
    /// an explicit "load more" step, so the UI and the store agree on what is
    /// listed.
    func list(limit: Int, offset: Int) async throws -> [Session]

    /// Append a message to a session.
    func appendMessage(sessionID: String, message: Message) async throws
}

/// Convenience for callers that want only the most recent page (offset 0).
extension SessionStore {
    public func list(limit: Int) async throws -> [Session] {
        try await list(limit: limit, offset: 0)
    }
}

/// A file-based session store that persists sessions as JSON files.
///
/// Each session is stored as a separate JSON file under the sessions directory.
/// This is the no-dependency fallback backend; production deployments use
/// ``TesseraSessionStore``.
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
        var session = try JSONDecoder().decode(Session.self, from: data)
        session.messageCount = session.messages.count
        return session
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

    public func list(limit: Int, offset: Int) async throws -> [Session] {
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
        .dropFirst(max(0, offset))
        .prefix(limit)

        var sessions: [Session] = []
        for file in files {
            let data = try Data(contentsOf: file)
            if var session = try? JSONDecoder().decode(Session.self, from: data) {
                session.messageCount = session.messages.count
                session.messages = []
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
