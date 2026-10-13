import Foundation

// MARK: - Unified skill management (reference `tools/skill_manager_tool.py` +
// `tools/skills_tool.py` skills_list parity)

/// Tool: `skill_manage` — unified create/patch/edit/delete/write_file/remove_file
/// for skills. The ONLY sanctioned agent path for skill writes while the
/// AgentPowers lockdown is active (same guard family as the old split tools).
public enum SkillManageTool {

    static let actions = "create, patch, edit, delete, write_file, remove_file"

    public static let entry = ToolEntry(
        name: "skill_manage",
        toolset: "skills",
        description: "Manage skills (create, update, delete). Skills are your procedural "
            + "memory — reusable approaches for recurring task types. "
            + "Actions: create (full SKILL.md + optional category), patch "
            + "(old_string/new_string — preferred for fixes), edit (full SKILL.md rewrite — "
            + "major overhauls only), delete, write_file, remove_file. "
            + "Good skills: trigger conditions, numbered steps with exact commands, pitfalls "
            + "section, verification steps. Use skills_list/skill_view to see formats.",
        schema: .object(
            description: "Skill management parameters",
            properties: [
                "action": .string(description: "One of: \(actions)"),
                "name": .string(description: "Skill name (lowercase, digits, hyphens, underscores; 1-64 chars)."),
                "content": .string(description: "Full SKILL.md content (YAML frontmatter with name + description, then body). For create/edit."),
                "category": .string(description: "Optional category (e.g. 'devops'); written into frontmatter for create."),
                "file_path": .string(description: "Relative path inside the skill directory (e.g. 'references/api.md')."),
                "file_content": .string(description: "Content for write_file."),
                "old_string": .string(description: "Exact text to find (patch)."),
                "new_string": .string(description: "Replacement text (patch)."),
                "replace_all": .boolean(description: "Replace all occurrences instead of the first (patch, default false)."),
                "absorbed_into": .string(description: "On delete: umbrella skill this is merging into, or \"\" when pruning."),
            ],
            required: ["action"]
        ),
        handler: { args in
            let action = (args["action"] as? String) ?? ""
            let name = (args["name"] as? String) ?? ""
            switch action {
            case "create": return try await performCreate(args, name: name)
            case "patch": return try await performPatch(args, name: name)
            case "edit": return try await performEdit(args, name: name)
            case "delete": return try await performDelete(args, name: name)
            case "write_file": return try await performWriteFile(args, name: name)
            case "remove_file": return try await performRemoveFile(args, name: name)
            default:
                return "Error: unknown action '\(action)'. Valid actions: \(actions)"
            }
        },
        emoji: "🛠️"
    )

    // MARK: - Actions

    static func performCreate(_ args: [String: Any], name: String) async throws -> String {
        guard SkillFileOps.isValidName(name) else {
            return "Error: invalid skill name '\(name)'. Use lowercase letters, digits, hyphens or underscores (1-64 chars)."
        }
        if let refusal = AgentPowers.skillWriteRefusal(name: name) {
            return "Error: " + refusal
        }
        let content = (args["content"] as? String) ?? ""
        if let err = validateFrontmatter(content, newSkill: true) { return "Error: \(err)" }
        var finalContent = content
        let category = (args["category"] as? String) ?? ""
        if !category.isEmpty {
            if let err = validateCategory(category) { return "Error: \(err)" }
            finalContent = injectFrontmatter(content, key: "category", value: category)
        }
        let url = SkillFileOps.skillURL(name: name)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return "Error: skill '\(name)' already exists at \(url.deletingLastPathComponent().path). Use action=patch/edit to modify it."
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try finalContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "Error: could not create skill: \(error.localizedDescription)"
        }
        return "Created skill '\(name)' at \(url.path)."
    }

    static func performPatch(_ args: [String: Any], name: String) async throws -> String {
        guard SkillFileOps.isValidName(name) else {
            return "Error: invalid skill name '\(name)'."
        }
        if let refusal = AgentPowers.skillWriteRefusal(name: name) {
            return "Error: " + refusal
        }
        let old = (args["old_string"] as? String) ?? ""
        let new = (args["new_string"] as? String) ?? ""
        guard !old.isEmpty else { return "Error: 'old_string' is required for patch." }
        let url = SkillFileOps.skillURL(name: name)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: skill '\(name)' not found at \(url.path). Use action=create to create it."
        }
        let replaceAll = (args["replace_all"] as? Bool) ?? false
        let count: Int
        if replaceAll {
            count = existing.components(separatedBy: old).count - 1
            guard count > 0 else { return "Error: 'old_string' not found in '\(name)'." }
            let patched = existing.replacingOccurrences(of: old, with: new)
            try? patched.write(to: url, atomically: true, encoding: .utf8)
        } else {
            guard let range = existing.range(of: old) else {
                return "Error: 'old_string' not found in '\(name)'."
            }
            count = 1
            let patched = existing.replacingCharacters(in: range, with: new)
            try? patched.write(to: url, atomically: true, encoding: .utf8)
        }
        return "Patched skill '\(name)' (1 occurrence\(count > 1 ? ", \(count) total" : ""))."
    }

    static func performEdit(_ args: [String: Any], name: String) async throws -> String {
        guard SkillFileOps.isValidName(name) else {
            return "Error: invalid skill name '\(name)'."
        }
        if let refusal = AgentPowers.skillWriteRefusal(name: name) {
            return "Error: " + refusal
        }
        let content = (args["content"] as? String) ?? ""
        if let err = validateFrontmatter(content, newSkill: false) { return "Error: \(err)" }
        let url = SkillFileOps.skillURL(name: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Error: skill '\(name)' not found at \(url.path). Use action=create to create it."
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "Error: could not update skill: \(error.localizedDescription)"
        }
        return "Updated skill '\(name)' at \(url.path)."
    }

    static func performDelete(_ args: [String: Any], name: String) async throws -> String {
        guard SkillFileOps.isValidName(name) else {
            return "Error: invalid skill name '\(name)'."
        }
        if let refusal = AgentPowers.skillWriteRefusal(name: name) {
            return "Error: " + refusal
        }
        let dir = SkillFileOps.baseDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return "Error: skill '\(name)' not found."
        }
        var consumed = ""
        if let absorbed = args["absorbed_into"] as? String {
            consumed = absorbed.isEmpty
                ? "(pruned; no forwarding target)"
                : "(merged into '\(absorbed)')"
        }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            return "Error: could not delete skill: \(error.localizedDescription)"
        }
        return "Deleted skill '\(name)' \(consumed)."
    }

    static func performWriteFile(_ args: [String: Any], name: String) async throws -> String {
        guard SkillFileOps.isValidName(name) else {
            return "Error: invalid skill name '\(name)'."
        }
        if let refusal = AgentPowers.skillWriteRefusal(name: name) {
            return "Error: " + refusal
        }
        let rel = (args["file_path"] as? String) ?? ""
        let content = (args["file_content"] as? String) ?? ""
        guard let resolved = try resolvedPath(name: name, relative: rel) else {
            return "Error: 'file_path' must be a relative path inside the skill directory and must not contain '..'."
        }
        do {
            try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: resolved, atomically: true, encoding: .utf8)
        } catch {
            return "Error: could not write file: \(error.localizedDescription)"
        }
        return "Wrote \(rel) to skill '\(name)'."
    }

    static func performRemoveFile(_ args: [String: Any], name: String) async throws -> String {
        guard SkillFileOps.isValidName(name) else {
            return "Error: invalid skill name '\(name)'."
        }
        if let refusal = AgentPowers.skillWriteRefusal(name: name) {
            return "Error: " + refusal
        }
        let rel = (args["file_path"] as? String) ?? ""
        guard let resolved = try resolvedPath(name: name, relative: rel) else {
            return "Error: 'file_path' must be a relative path inside the skill directory and must not contain '..'."
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return "Error: \(rel) does not exist in skill '\(name)'."
        }
        do {
            try FileManager.default.removeItem(at: resolved)
        } catch {
            return "Error: could not remove file: \(error.localizedDescription)"
        }
        return "Removed \(rel) from skill '\(name)'."
    }

    // MARK: - Validation

    static func validateFrontmatter(_ content: String, newSkill: Bool) -> String? {
        guard content.hasPrefix("---\n") else {
            return "content must start with a YAML frontmatter block (---\\n...)"
        }
        guard let end = content.range(of: "\n---\n") else {
            return "content frontmatter must be closed by a '---' line."
        }
        let front = content[content.index(content.startIndex, offsetBy: 4)..<end.lowerBound]
        var hasName = false, hasDescription = false
        for line in front.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("name:") { hasName = true }
            if t.hasPrefix("description:") { hasDescription = true }
        }
        if !hasName { return "frontmatter is missing 'name:'." }
        if !hasDescription { return "frontmatter is missing 'description:'." }
        if content.count > 200_000 { return "skill content is too large (max 200000 chars)." }
        return nil
    }

    static func validateCategory(_ category: String) -> String? {
        let pattern = #"^[a-z0-9][a-z0-9-_]*$"#
        guard category.range(of: pattern, options: .regularExpression) != nil else {
            return "invalid category '\(category)'. Use lowercase letters, digits, hyphens, underscores."
        }
        return nil
    }

    static func injectFrontmatter(_ content: String, key: String, value: String) -> String {
        guard content.hasPrefix("---\n"), let end = content.range(of: "\n---\n") else { return content }
        let front = String(content[content.index(content.startIndex, offsetBy: 4)..<end.lowerBound])
        let body = String(content[end.upperBound...])
        return "---\n\(front)\n\(key): \(value)\n---\n\(body)"
    }

    /// Resolve `relative` inside <skillDir>/<name>/, rejecting traversal.
    static func resolvedPath(name: String, relative: String) throws -> URL? {
        let rel = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rel.isEmpty else { return nil }
        let base = SkillFileOps.baseDirectory.appendingPathComponent(name)
        let candidate = base.appendingPathComponent(rel).standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}

/// Tool: `skills_list` — list available skills (name + description).
public enum SkillsListTool {
    public static let entry = ToolEntry(
        name: "skills_list",
        toolset: "skills",
        description: "List available skills (name + description). Use skill_view(name) to load full content.",
        schema: .object(
            description: "Skill list parameters",
            properties: [
                "category": .string(description: "Optional category filter to narrow results"),
            ],
            required: []
        ),
        handler: { args in
            let category = (args["category"] as? String) ?? ""
            let skills = discoverSkills()
            let filtered = category.isEmpty
                ? skills
                : skills.filter { ($0.category ?? "").lowercased() == category.lowercased() }
            if filtered.isEmpty {
                return "No skills found\(category.isEmpty ? "" : " in category '\(category)'")."
            }
            var lines: [String] = ["Available skills:", ""]
            var byCategory: [(String, [Skill])] = []
            for skill in filtered {
                let cat = skill.category ?? "general"
                if let idx = byCategory.firstIndex(where: { $0.0 == cat }) {
                    byCategory[idx].1.append(skill)
                } else {
                    byCategory.append((cat, [skill]))
                }
            }
            for (cat, skills) in byCategory.sorted(by: { $0.0 < $1.0 }) {
                lines.append("📚 \(cat)")
                for skill in skills.sorted(by: { $0.name < $1.name }) {
                    lines.append("  \(skill.name) — \(skill.description)")
                }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        },
        emoji: "📚"
    )
}
