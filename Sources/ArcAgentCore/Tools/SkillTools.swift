import Foundation

// MARK: - Skill creation / editing tools
//
// The ONLY sanctioned agent path for creating and editing skills while the
// lockdown is active (see ``AgentPowers``). Both tools refuse when the global
// skills lock is on or the named skill is individually locked, and edit
// integrations (write_file, terminal) refuse paths under the skills
// directory at the same time — so these two tools are the only way in until
// the user unlocks a surface in Settings → Agent powers.

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

/// Tool: `skill_creation` — create a new skill under `~/.arc/skills/<name>/SKILL.md`.
public enum SkillCreationTool {

    public static let entry = ToolEntry(
        name: "skill_creation",
        toolset: "skills",
        description: "Create a new skill. The ONLY sanctioned way to create skills "
            + "while lockdowns are active. Refused when skill creation is locked in "
            + "Settings (Agent powers).",
        schema: .object(
            description: "Skill creation parameters",
            properties: [
                "name": .string(description: "Lowercase skill name (letters, digits, hyphens, underscores; 1-64 chars)."),
                "description": .string(description: "One-line description of what the skill does and when to use it."),
                "content": .string(description: "The skill body (markdown instructions)."),
            ],
            required: ["name", "description", "content"]
        ),
        handler: { args in
            let name = (args["name"] as? String) ?? ""
            let description = (args["description"] as? String) ?? ""
            let content = (args["content"] as? String) ?? ""

            guard SkillFileOps.isValidName(name) else {
                return "Error: invalid skill name '\(name)'. Use lowercase letters, digits, hyphens or underscores (1-64 chars)."
            }
            if let refusal = AgentPowers.skillWriteRefusal(name: name) {
                return "Error: " + refusal
            }
            let url = SkillFileOps.skillURL(name: name)
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                return "Error: skill '\(name)' already exists at \(url.deletingLastPathComponent().path). Use skill_edit to modify it."
            }
            do {
                try fm.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try SkillFileOps.renderSKILLMD(name: name, description: description, body: content)
                    .write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return "Error: could not create skill: \(error.localizedDescription)"
            }
            return "Created skill '\(name)' at \(url.path)."
        },
        emoji: "✨"
    )
}

/// Tool: `skill_edit` — update an existing skill's SKILL.md.
public enum SkillEditTool {

    public static let entry = ToolEntry(
        name: "skill_edit",
        toolset: "skills",
        description: "Edit an existing skill's SKILL.md. The ONLY sanctioned way to edit "
            + "skills while lockdowns are active. Refused for locked skills and when skill "
            + "editing is locked in Settings (Agent powers).",
        schema: .object(
            description: "Skill edit parameters",
            properties: [
                "name": .string(description: "The exact skill name to edit."),
                "description": .string(description: "Replacement one-line description (optional; keeps current if omitted)."),
                "content": .string(description: "Replacement body for SKILL.md (the frontmatter is rebuilt; other frontmatter keys are preserved)."),
            ],
            required: ["name", "content"]
        ),
        handler: { args in
            let name = (args["name"] as? String) ?? ""
            let content = (args["content"] as? String) ?? ""

            guard SkillFileOps.isValidName(name) else {
                return "Error: invalid skill name '\(name)'."
            }
            if let refusal = AgentPowers.skillWriteRefusal(name: name) {
                return "Error: " + refusal
            }
            let url = SkillFileOps.skillURL(name: name)
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path),
                  let existing = try? String(contentsOf: url, encoding: .utf8) else {
                return "Error: skill '\(name)' not found at \(url.path). Use skill_creation to create it."
            }
            let description = (args["description"] as? String) ?? SkillFileOps.existingDescription(of: existing) ?? ""
            do {
                try SkillFileOps.editSKILLMD(name: name, description: description, body: content, existing: existing)
                    .write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return "Error: could not update skill: \(error.localizedDescription)"
            }
            return "Updated skill '\(name)' at \(url.path)."
        },
        emoji: "✏️"
    )
}
