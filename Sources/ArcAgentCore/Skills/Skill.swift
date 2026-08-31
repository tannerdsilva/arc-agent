import Foundation

/// A skill loaded from a SKILL.md file.
///
/// Skills are reusable procedural knowledge — workflows, commands, and
/// conventions for recurring task types. They are stored as markdown files
/// with YAML frontmatter under `~/.arc/skills/`.
///
/// ## File Format
///
/// ```markdown
/// ---
/// name: my-skill
/// description: Use when doing X. Does Y.
/// tags: [swift, networking]
/// category: software-development
/// ---
///
/// # My Skill
///
/// Step-by-step instructions...
/// ```
public struct Skill: Sendable, Codable, Equatable {

    /// The skill name (lowercase, hyphens/underscores).
    public let name: String

    /// Short description (first ~57 chars shown in the prompt index).
    public let description: String

    /// Full SKILL.md content (frontmatter + body).
    public let content: String

    /// Tags for categorization.
    public let tags: [String]

    /// Optional category/domain (e.g. "devops", "data-science").
    public let category: String?

    /// The file path this skill was loaded from.
    public let path: URL

    public init(
        name: String,
        description: String,
        content: String,
        tags: [String] = [],
        category: String? = nil,
        path: URL
    ) {
        self.name = name
        self.description = description
        self.content = content
        self.tags = tags
        self.category = category
        self.path = path
    }
}

// MARK: - Discovery

/// Errors that can occur during skill discovery.
public enum SkillError: Error, Sendable, CustomStringConvertible {
    case invalidFrontmatter(String)
    case missingField(String)

    public var description: String {
        switch self {
        case .invalidFrontmatter(let path):
            return "Invalid YAML frontmatter in skill: \(path)"
        case .missingField(let field):
            return "Missing required field '\(field)' in skill frontmatter"
        }
    }
}

/// Discover skills by scanning for SKILL.md files.
///
/// - Parameter directory: The directory to scan. Defaults to `~/.arc/skills/`.
/// - Returns: An array of discovered skills, sorted by name.
public func discoverSkills(in directory: URL? = nil) -> [Skill] {
    let defaultDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".arc/skills")
    let dir = directory ?? defaultDir

    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

    let enumerator = FileManager.default.enumerator(
        at: dir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )

    var skills: [Skill] = []

    while let file = enumerator?.nextObject() as? URL {
        guard file.lastPathComponent == "SKILL.md" else { continue }

        guard let data = try? Data(contentsOf: file),
              let content = String(data: data, encoding: .utf8)
        else { continue }

        if let skill = parseSkillFile(content: content, path: file) {
            skills.append(skill)
        }
    }

    return skills.sorted { $0.name < $1.name }
}

// MARK: - Parsing

/// Parse a SKILL.md file into a ``Skill``.
///
/// The file must have YAML frontmatter delimited by `---` lines:
///
/// ```markdown
/// ---
/// name: my-skill
/// description: Does X
/// ---
/// ```
func parseSkillFile(content: String, path: URL) -> Skill? {
    let lines = content.components(separatedBy: .newlines)

    // Must start with "---"
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
        return nil
    }

    // Find the closing "---"
    guard let endIndex = lines[1...].firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "---"
    }) else {
        return nil
    }

    // Parse frontmatter lines
    let frontmatterLines = lines[1..<endIndex]
    var frontmatter: [String: String] = [:]

    for line in frontmatterLines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

        if let colonIndex = trimmed.firstIndex(of: ":") {
            let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            frontmatter[key] = value
        }
    }

    guard let name = frontmatter["name"], !name.isEmpty else { return nil }
    let description = frontmatter["description"] ?? ""

    // Parse tags (comma-separated in brackets or plain)
    let tags: [String]
    if let tagsStr = frontmatter["tags"] {
        tags = tagsStr
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    } else {
        tags = []
    }

    let category = frontmatter["category"]

    return Skill(
        name: name,
        description: description,
        content: content,
        tags: tags,
        category: category,
        path: path
    )
}

// MARK: - Prompt Index

/// Build a compact skills index for inclusion in the system prompt.
///
/// Each skill is shown as a single line with its name and truncated
/// description (first 57 characters), matching the Hermes Agent format.
///
/// - Parameter skills: The skills to include.
/// - Returns: A formatted string for the system prompt.
public func buildSkillsIndex(_ skills: [Skill]) -> String {
    guard !skills.isEmpty else { return "No skills available." }

    return skills.map { skill in
        let desc = skill.description.count > 57
            ? String(skill.description.prefix(57)) + "..."
            : skill.description
        let category = skill.category.map { "[\($0)] " } ?? ""
        return "- \(category)`\(skill.name)`: \(desc)"
    }.joined(separator: "\n")
}
