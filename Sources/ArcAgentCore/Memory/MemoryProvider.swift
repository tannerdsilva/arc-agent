import ArcToolKit
import Foundation

// The ``MemoryProvider`` protocol itself lives in `ArcToolKit`: it needs
// nothing but the standard library, so a memory policy written against it
// cannot open a file. What stays here needs Foundation — the file-backed
// implementation (a `URL` and `FileManager`) and the recall regex below.

/// Trivial-prompt detection for memory recall (reference
/// `memory_provider.is_trivial_prompt`): empty text, slash commands, and
/// bare greetings/acknowledgements carry no semantic signal, so the
/// prefetch round-trip is skipped.
public enum MemoryRecall {
    /// reference `TRIVIAL_PROMPT_RE` port (case-insensitive).
    private static let trivialRegex = try? NSRegularExpression(
        pattern: #"^(yes|no|ok|okay|sure|thanks|thank you|y|n|yep|nope|yeah|nah|hi|hey|hello|yo|sup|continue|go ahead|do it|proceed|got it|cool|nice|great|done|next|lgtm|k)[\s!?.:;,"'~‘’“”—–…()\[\]{}<>*&^%$#@!+=` ]*$"#,
        options: [.caseInsensitive]
    )

    public static func isTrivialPrompt(_ text: String?) -> Bool {
        guard let text else { return true }
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return true }
        if stripped.hasPrefix("/") { return true }
        return trivialRegex?.firstMatch(
            in: stripped,
            range: NSRange(stripped.startIndex..., in: stripped)
        ) != nil
    }

    /// Run prefetch with a bounded timeout; a stuck provider must never
    /// stall the turn (reference: join(timeout), non-fatal).
    public static func prefetchWithTimeout(
        timeout: Duration = .seconds(2),
        _ op: @escaping @Sendable () async throws -> String
    ) async -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await op() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
        } catch {
            return ""
        }
    }
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
        let defaultDir = ArcHome.memories
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

    public func writeUser(_ text: String) async throws {
        try text.write(to: userPath, atomically: true, encoding: .utf8)
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
