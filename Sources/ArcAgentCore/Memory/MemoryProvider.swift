import Foundation

/// A provider for the agent's persistent memory system.
///
/// ``MemoryProvider`` abstracts the storage of two memory files:
/// - **MEMORY.md** — the agent's persistent notes (environment facts, tool quirks, conventions)
/// - **USER.md** — the user's profile (name, role, preferences, style)
///
/// Both are injected into the system prompt at the start of each session and
/// updated when the agent calls the `memory` tool.
///
/// ## Design (Protocols First)
///
/// 1. **Protocol** — ``MemoryProvider`` (this protocol)
/// 2. **Concrete types** — ``FileMemoryProvider``
/// 3. **Macros** — None needed
///
/// The protocol is intentionally minimal. If a second implementation emerges
/// (e.g. an LMDB-backed store), the protocol is validated. If not, it may be
/// collapsed into the concrete type once the design is stable.
public protocol MemoryProvider: Sendable {

    /// Read the MEMORY.md content.
    func readMemory() async throws -> String

    /// Read the USER.md content.
    func readUser() async throws -> String

    /// Append text to MEMORY.md.
    func appendMemory(_ text: String) async throws

    /// Replace text in MEMORY.md (find-and-replace).
    func replaceMemory(old: String, new: String) async throws

    /// Overwrite MEMORY.md with the given content.
    func writeMemory(_ text: String) async throws

    /// Append text to USER.md.
    func appendUser(_ text: String) async throws

    /// Replace text in USER.md (find-and-replace).
    func replaceUser(old: String, new: String) async throws
}

/// A file-based memory provider that stores memories as markdown files.
///
/// ## File Layout
/// ```
/// ~/.arc/memories/
/// ├── MEMORY.md         # Agent's persistent notes
/// └── USER.md           # User profile
/// ```
public struct FileMemoryProvider: MemoryProvider {

    /// The directory where memory files are stored.
    public let directory: URL

    /// Path to MEMORY.md.
    private var memoryPath: URL { directory.appendingPathComponent("MEMORY.md") }

    /// Path to USER.md.
    private var userPath: URL { directory.appendingPathComponent("USER.md") }

    /// Create a file-based memory provider.
    ///
    /// - Parameter directory: The directory for memory files.
    ///   Defaults to `~/.arc/memories/`.
    public init(directory: URL? = nil) {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/memories")
        self.directory = directory ?? defaultDir
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - MemoryProvider

    public func readMemory() async throws -> String {
        try await readFile(at: memoryPath)
    }

    public func readUser() async throws -> String {
        try await readFile(at: userPath)
    }

    public func appendMemory(_ text: String) async throws {
        try await appendToFile(at: memoryPath, text: text)
    }

    public func replaceMemory(old: String, new: String) async throws {
        try await replaceInFile(at: memoryPath, old: old, new: new)
    }

    public func writeMemory(_ text: String) async throws {
        try text.write(to: memoryPath, atomically: true, encoding: .utf8)
    }

    public func appendUser(_ text: String) async throws {
        try await appendToFile(at: userPath, text: text)
    }

    public func replaceUser(old: String, new: String) async throws {
        try await replaceInFile(at: userPath, old: old, new: new)
    }

    // MARK: - File Operations

    private func readFile(at path: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: path.path) else { return "" }
        let data = try Data(contentsOf: path)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func appendToFile(at path: URL, text: String) async throws {
        let existing = try await readFile(at: path)
        let newContent: String
        if existing.isEmpty {
            newContent = text
        } else {
            newContent = existing + "\n" + text
        }
        try newContent.write(to: path, atomically: true, encoding: .utf8)
    }

    private func replaceInFile(at path: URL, old: String, new: String) async throws {
        var content = try await readFile(at: path)
        guard !content.isEmpty else { return }
        content = content.replacingOccurrences(of: old, with: new)
        try content.write(to: path, atomically: true, encoding: .utf8)
    }
}
