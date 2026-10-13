import Foundation

// MARK: - Skill file helpers
//
// The ONLY sanctioned agent path for creating and editing skills while the
// lockdown is active is ``SkillManageTool`` (the unified arc-parity tool
// with create/patch/edit/delete/write_file/remove_file). These helpers are
// shared by that tool; they refuse when the global skills lock is on or the
// named skill is individually locked, and edit integrations (write_file,
// terminal) refuse paths under the skills directory at the same time — so
// skill_manage is the only way in until the user unlocks a surface in
// Settings → Agent powers.

/// Shared helpers for the skill tools.
enum SkillFileOps {

    /// Base directory for skills. Defaults to ``AgentPowers/skillsDirectory``
    /// so tests can redirect by overriding that.
    static var baseDirectory: URL {
        AgentPowers.skillsDirectory
    }

    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        let pattern = #"^[a-z0-9][a-z0-9-_]*$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    static func skillURL(name: String) -> URL {
        baseDirectory.appendingPathComponent(name).appendingPathComponent("SKILL.md")
    }

    /// Build a SKILL.md with frontmatter (name + description) and body.
    static func renderSKILLMD(name: String, description: String, body: String) -> String {
        let desc = description
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "---\nname: \(name)\ndescription: \(desc)\n---\n\n\(trimmedBody)\n"
    }

    /// Extract the description from an existing SKILL.md frontmatter.
    static func existingDescription(of content: String) -> String? {
        guard content.hasPrefix("---\n") else { return nil }
        let rest = content.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") else { return nil }
        let frontmatter = rest[..<end.lowerBound]
        for line in frontmatter.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("description:") {
                return String(line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Edit a SKILL.md preserving unknown frontmatter keys (only
    /// `name`/`description` are replaced).
    static func editSKILLMD(name: String, description: String, body: String, existing: String) -> String {
        if existing.hasPrefix("---\n"), let end = existing.range(of: "\n---\n") {
            let front = existing.dropFirst(4)[..<end.lowerBound]
            var kept: [String] = []
            for line in front.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("name:") || t.hasPrefix("description:") { continue }
                kept.append(String(t))
            }
            let desc = description
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let head = "---\nname: \(name)\ndescription: \(desc)\n"
                + kept.joined(separator: "\n") + "\n---\n\n"
            return head + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        return renderSKILLMD(name: name, description: description, body: body)
    }

    /// Strip the frontmatter block, returning the body only.
    static func body(of content: String) -> String {
        guard content.hasPrefix("---\n"), let end = content.range(of: "\n---\n") else {
            return content
        }
        return String(content[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
