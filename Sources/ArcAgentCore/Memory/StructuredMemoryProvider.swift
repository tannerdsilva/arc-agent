import Foundation

/// The type of a memory entry.
public enum MemoryEntryType: String, Sendable, Codable {
    /// A stable fact about the environment, user, or system.
    case fact
    /// A reusable procedure, workflow, or command.
    case procedure
    /// A user preference, style, or personal detail.
    case profile
}

/// A single structured memory entry.
public struct MemoryEntry: Sendable, Codable, Hashable {
    /// The type of memory.
    public let type: MemoryEntryType
    /// The content of the entry.
    public let content: String
    /// When this entry was created.
    public let createdAt: Date
    /// Optional TTL in seconds. Nil = never expires.
    public let ttl: TimeInterval?
    /// A content hash for deduplication.
    public let contentHash: String

    public init(type: MemoryEntryType, content: String, ttl: TimeInterval? = nil) {
        self.type = type
        self.content = content
        self.createdAt = Date()
        self.ttl = ttl
        self.contentHash = Self.hash(content)
    }

    /// Whether this entry has expired.
    public var isExpired: Bool {
        guard let ttl else { return false }
        return Date().timeIntervalSince(createdAt) > ttl
    }

    /// Create a content hash for deduplication.
    private static func hash(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(trimmed.prefix(200))
    }
}

/// A structured memory provider that organizes entries by type.
///
/// ``StructuredMemoryProvider`` wraps an underlying ``MemoryProvider`` and
/// adds structured storage with:
/// - **Typed entries**: facts, procedures, and profile preferences
/// - **Deduplication**: entries with the same content hash are not duplicated
/// - **TTL-based eviction**: expired entries are filtered out on read
/// - **Sectioned output**: entries are formatted into markdown sections
///
/// ## Storage Format
///
/// Entries are stored as newline-separated JSON objects in the underlying
/// memory store. Each line is a single ``MemoryEntry`` JSON object.
///
/// ## Usage
///
/// ```swift
/// let provider = StructuredMemoryProvider(wrapping: LMDBMemoryProvider())
/// try await provider.addEntry(.fact, "Server runs Ubuntu 24.04")
/// let memory = try await provider.readFormatted()
/// // Returns:
/// // ## Facts
/// // - Server runs Ubuntu 24.04
/// //
/// // ## Procedures
/// // - Deploy with: `arc deploy`
/// ```
public struct StructuredMemoryProvider: Sendable {
    private let underlying: any MemoryProvider
    private let tokenCounter: TokenCounter

    /// Maximum total characters for formatted memory output.
    /// Prevents memory from dominating the context window.
    public var maxFormattedLength: Int = 2000

    /// Create a structured memory provider wrapping an underlying provider.
    /// - Parameter underlying: The base memory provider (LMDB or file).
    public init(wrapping underlying: any MemoryProvider) {
        self.underlying = underlying
        self.tokenCounter = TokenCounter()
    }

    // MARK: - Public API

    /// Add a memory entry, deduplicating by content hash.
    public func addEntry(_ type: MemoryEntryType, _ content: String, ttl: TimeInterval? = nil) async throws {
        let entry = MemoryEntry(type: type, content: content, ttl: ttl)
        let store = try await loadEntries()

        // Deduplicate: skip if same content hash exists for this type
        if store.contains(where: { $0.contentHash == entry.contentHash && $0.type == entry.type }) {
            return
        }

        var updated = store
        updated.append(entry)
        try await saveEntries(updated)
    }

    /// Read all non-expired entries as a formatted markdown string.
    public func readFormatted() async throws -> String {
        let entries = try await loadEntries().filter { !$0.isExpired }
        return formatEntries(entries)
    }

    /// Read all entries as raw data (for tool use).
    public func readRaw() async throws -> [MemoryEntry] {
        try await loadEntries().filter { !$0.isExpired }
    }

    /// Remove an entry by its content hash.
    public func removeEntry(contentHash: String) async throws {
        var entries = try await loadEntries()
        entries.removeAll { $0.contentHash == contentHash }
        try await saveEntries(entries)
    }

    /// Remove all expired entries (compaction).
    public func compact() async throws {
        let entries = try await loadEntries().filter { !$0.isExpired }
        try await saveEntries(entries)
    }

    /// Get the count of entries per type.
    public func counts() async throws -> [MemoryEntryType: Int] {
        let entries = try await loadEntries().filter { !$0.isExpired }
        var counts: [MemoryEntryType: Int] = [:]
        for entry in entries {
            counts[entry.type, default: 0] += 1
        }
        return counts
    }

    // MARK: - Private

    /// Load all entries from the underlying store.
    private func loadEntries() async throws -> [MemoryEntry] {
        let raw = try await underlying.readMemory()
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(MemoryEntry.self, from: data)
        }
    }

    /// Save all entries to the underlying store.
    private func saveEntries(_ entries: [MemoryEntry]) async throws {
        let lines = entries.compactMap { entry -> String? in
            guard let data = try? JSONEncoder().encode(entry) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        let raw = lines.joined(separator: "\n")
        try await underlying.writeMemory(raw)
    }

    /// Format entries into a markdown string with sections.
    private func formatEntries(_ entries: [MemoryEntry]) -> String {
        let facts = entries.filter { $0.type == .fact }
        let procedures = entries.filter { $0.type == .procedure }
        let profiles = entries.filter { $0.type == .profile }

        var sections: [String] = []

        if !facts.isEmpty {
            var section = "## Facts\n"
            for entry in facts {
                section += "- \(entry.content)\n"
            }
            sections.append(section)
        }

        if !procedures.isEmpty {
            var section = "## Procedures\n"
            for entry in procedures {
                section += "- \(entry.content)\n"
            }
            sections.append(section)
        }

        if !profiles.isEmpty {
            var section = "## User Profile\n"
            for entry in profiles {
                section += "- \(entry.content)\n"
            }
            sections.append(section)
        }

        let formatted = sections.joined(separator: "\n")

        // Truncate if too long
        if formatted.utf8.count > maxFormattedLength {
            let prefix = String(formatted.prefix(maxFormattedLength))
            return prefix + "\n\n<!-- Memory truncated: \(tokenCounter.count(formatted)) tokens estimated -->"
        }

        return formatted
    }
}
