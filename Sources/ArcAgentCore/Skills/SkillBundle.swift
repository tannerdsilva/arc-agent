import Foundation

// MARK: - Skill bundles (Hermes `skill_bundles.py`)

/// A portable skill bundle: one JSON file holding several skills (and their
/// reference files), plus the invocation messages that activate them.
/// Bundles live in `~/.arc/skill-bundles/` (Hermes keeps them in
/// HERMES_HOME/skill-bundles).
public struct SkillBundle: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let name: String
        public let content: String
        /// Relative paths (references/templates/scripts) inside the bundle.
        public let files: [String: String]
    }

    public let id: String
    public let slug: String
    public let name: String
    public let createdAt: Date
    /// Skill names activated with this bundle.
    public let skills: [Entry]
    /// Invocation messages (Hermes `invocation_messages`): the text that
    /// tells the agent the user invoked the bundle.
    public let invocationMessages: [String]

    public init(id: String? = nil, slug: String, name: String, createdAt: Date = Date(),
                skills: [Entry], invocationMessages: [String] = []) {
        self.id = id ?? slug
        self.slug = slug
        self.name = name
        self.createdAt = createdAt
        self.skills = skills
        self.invocationMessages = invocationMessages
    }

    /// Slugify a display name (Hermes `slugify`-style: lowercase, alphanumerics,
    /// dashes).
    public static func slugify(_ name: String) -> String {
        let lower = name.lowercased()
        let cleaned = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "-"
        }
        let result = String(cleaned)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "bundle" : result
    }

    /// Invocation fence for the bundle (Hermes invocation format).
    public static func invocationMessage(for bundleName: String, skillNames: [String]) -> String {
        let base = "[IMPORTANT: The user has invoked the \"\(bundleName)\" skill bundle."
        let skills = skillNames.isEmpty ? "" : " The following skills are preloaded: \(skillNames.joined(separator: ", "))."
        return base + skills + "]"
    }
}

public enum SkillBundleStore {
    /// The default bundle directory.
    public static func defaultDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".arc/skill-bundles", isDirectory: true)
    }

    public static func save(_ bundle: SkillBundle, directory: URL = SkillBundleStore.defaultDirectory()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(bundle.slug).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bundle).write(to: url, options: .atomic)
        return url
    }

    public static func delete(slug: String, directory: URL = SkillBundleStore.defaultDirectory()) throws {
        let url = directory.appendingPathComponent("\(slug).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func load(slug: String, directory: URL = SkillBundleStore.defaultDirectory()) throws -> SkillBundle? {
        let url = directory.appendingPathComponent("\(slug).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SkillBundle.self, from: data)
    }

    /// All bundles, newest first (Hermes lists with mtime cache).
    public static func list(directory: URL = SkillBundleStore.defaultDirectory()) throws -> [SkillBundle] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var bundles: [SkillBundle] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let bundle = try? decoder.decode(SkillBundle.self, from: data) {
                bundles.append(bundle)
            }
        }
        return bundles.sorted { $0.createdAt > $1.createdAt }
    }
}
