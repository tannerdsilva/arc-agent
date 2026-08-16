import Foundation

/// The `skill_view` tool: load a skill's full content by name.
///
/// Skills are stored as SKILL.md files under `~/.arc/skills/`. This tool
/// discovers and returns the full content of a named skill so the LLM can
/// follow its instructions.
struct SkillViewTool {

    static let entry = ToolEntry(
        name: "skill_view",
        toolset: "core",
        description: "Load a skill's full content by name. "
            + "Use this when the skills index mentions a skill you need to follow. "
            + "Pass the exact skill name as shown in the Available Skills section.",
        schema: .object(
            description: "Skill view parameters",
            properties: [
                "name": .string(
                    description: "The exact skill name to load (e.g. 'my-skill')"
                ),
            ],
            required: ["name"]
        ),
        handler: { args in
            guard let name = args["name"] as? String, !name.isEmpty else {
                return "Error: 'name' is required."
            }

            let skillsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".arc/skills")

            guard FileManager.default.fileExists(atPath: skillsDir.path) else {
                return "Error: Skills directory not found at \(skillsDir.path)."
            }

            // Recursively search for SKILL.md files
            let found = findSkillFile(named: name, in: skillsDir)
            if let url = found {
                let content = try String(contentsOf: url, encoding: .utf8)
                return content
            }

            return "Error: Skill '\(name)' not found. Available skills are listed in the Available Skills section."
        },
        emoji: "📚"
    )
}

/// Recursively search for a SKILL.md file matching the given skill name.
private func findSkillFile(named name: String, in directory: URL) -> URL? {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }

    for url in contents {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            continue
        }

        if isDir.boolValue {
            // Recurse into subdirectory
            if let found = findSkillFile(named: name, in: url) {
                return found
            }
        } else if url.lastPathComponent == "SKILL.md" {
            // Check if the parent directory name matches the requested skill name
            let parentDir = url.deletingLastPathComponent().lastPathComponent
            if parentDir == name {
                return url
            }
        }
    }

    return nil
}
