import Foundation

// MARK: - Slash-command skill invocation (Hermes parity: agent/skill_commands.py)

/// Metadata for a skill registered as a slash command.
public struct SkillCommandInfo: Sendable, Equatable {
    /// Display name from the skill frontmatter.
    public let name: String
    /// Short description from the skill frontmatter.
    public let description: String
    /// Absolute path of the SKILL.md file.
    public let skillMDURL: URL
    /// Directory containing the skill (parent of SKILL.md).
    public let skillDir: URL

    public init(name: String, description: String, skillMDURL: URL, skillDir: URL) {
        self.name = name
        self.description = description
        self.skillMDURL = skillMDURL
        self.skillDir = skillDir
    }
}

/// Slash-command helpers for skills.
///
/// A `/skill-name` (optionally stacked: `/skill-a /skill-b do XYZ`) typed at a
/// chat prompt is expanded into a model-facing user message that embeds the
/// full skill bodies plus scaffolding, mirroring Hermes' `agent/skill_commands.py`.
public enum SkillCommands {

    /// Maximum number of leading skills loaded by a stacked invocation
    /// (Hermes `_MAX_STACKED_SKILLS`).
    public static let maxStackedSkills = 5
    public static let maxStack = maxStackedSkills

    /// Invocation-message prefix used by ``invocationMessage`` (kept for the
    /// existing command-skill API).
    public static let invocationPrefix = "[IMPORTANT: The user has invoked the"

    /// Slash commands that are built into the arc webui; a skill whose
    /// generated `/slug` collides with one is not auto-registered as a
    /// command (Hermes skips such skills the same way).
    static let reservedCommandNames: Set<String> = [
        "help", "new", "usage", "theme", "skills", "use", "stop",
        "title", "workspace", "model", "clear", "compress", "compact",
    ]

    /// Normalize a skill name into a hyphen-separated slug, stripping
    /// non-alphanumeric characters (Hermes `_SKILL_INVALID_CHARS` /
    /// `_SKILL_MULTI_HYPHEN`).
    public static func sanitizeSlug(_ name: String) -> String {
        var s = name.lowercased().replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        s = s.replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        while s.contains("--") {
            s = s.replacingOccurrences(of: "--", with: "-")
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Scan the skills directory (default `~/.arc/skills/`) and return a
    /// mapping of `/slug` -> skill command info, sorted for stability and
    /// with first-wins dedup on the resolved slug.
    ///
    /// - Parameter directory: Skills root; defaults to `~/.arc/skills/`.
    public static func getSkillCommands(directory: URL? = nil) -> [String: SkillCommandInfo] {
        let skills = discoverSkills(in: directory)
        var commands: [String: SkillCommandInfo] = [:]
        for skill in skills {
            let slug = sanitizeSlug(skill.name)
            guard !slug.isEmpty else { continue }
            guard !reservedCommandNames.contains(slug) else { continue }
            let key = "/" + slug
            guard commands[key] == nil else { continue }
            commands[key] = SkillCommandInfo(
                name: skill.name,
                description: skill.description.isEmpty ? "Invoke the \(skill.name) skill" : skill.description,
                skillMDURL: skill.path,
                skillDir: skill.path.deletingLastPathComponent()
            )
        }
        return commands
    }

    /// Resolve a user-typed `/command` to its canonical `/slug` key.
    /// Hyphens and underscores are treated interchangeably (Hermes
    /// `resolve_skill_command_key`).
    public static func resolveSkillCommandKey(_ command: String, directory: URL? = nil) -> String? {
        guard !command.isEmpty else { return nil }
        let bare = command.hasPrefix("/") ? String(command.dropFirst()) : command
        let key = "/" + bare.replacingOccurrences(of: "_", with: "-")
        return getSkillCommands(directory: directory)[key] != nil ? key : nil
    }

    /// Build the user-message payload for a stacked multi-skill invocation.
    /// Returns `(message, loadedNames, missingNames)` or `nil` when no skill
    /// could be loaded at all (Hermes `build_stacked_skill_invocation_message`).
    public static func buildStackedSkillInvocationMessage(
        _ cmdKeys: [String],
        userInstruction: String = "",
        directory: URL? = nil
    ) -> (message: String, loaded: [String], missing: [String])? {
        let commands = getSkillCommands(directory: directory)
        var loadedNames: [String] = []
        var missing: [String] = []
        var blocks: [String] = []
        var seen = Set<String>()

        for key in cmdKeys {
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            guard let info = commands[key] else {
                missing.append(String(key.dropFirst()))
                continue
            }
            guard let content = try? String(contentsOf: info.skillMDURL, encoding: .utf8) else {
                missing.append(String(key.dropFirst()))
                continue
            }
            let activationNote = "[Loaded as part of the stacked skill invocation \"\(info.name)\".]"
            blocks.append(buildSkillMessage(info: info, content: content, activationNote: activationNote, supportingHint: true, directory: directory))
            loadedNames.append(info.name)
        }

        guard !blocks.isEmpty else { return nil }

        let typed = cmdKeys.filter { !$0.isEmpty }.joined(separator: " ")
        var header = ""
        header += "[IMPORTANT: The user has invoked the \"\(typed)\" stacked skill bundle, loading \(loadedNames.count) skills together. Treat every skill below as active guidance for this turn.]\n\n"
        header += "Skills loaded: \(loadedNames.joined(separator: ", "))"
        if !missing.isEmpty {
            header += "\nSkills missing (skipped): \(missing.joined(separator: ", "))"
        }
        if !userInstruction.isEmpty {
            header += "\n\nUser instruction: \(userInstruction)"
        }
        return (([header] + blocks).joined(separator: "\n\n"), loadedNames, missing)
    }

    /// Build the user-message payload for a single `/skill-name` invocation.
    /// Returns `nil` when the skill is unknown (Hermes
    /// `build_skill_invocation_message`).
    public static func buildSkillInvocationMessage(
        _ cmdKey: String,
        userInstruction: String = "",
        runtimeNote: String = "",
        directory: URL? = nil
    ) -> String? {
        let commands = getSkillCommands(directory: directory)
        guard let info = commands[cmdKey] else { return nil }
        guard let content = try? String(contentsOf: info.skillMDURL, encoding: .utf8) else { return nil }
        let activationNote = "[IMPORTANT: The user has invoked the \"\(info.name)\" skill, indicating they want you to follow its instructions. The full skill content is loaded below.]"
        return buildSkillMessage(
            info: info,
            content: content,
            activationNote: activationNote,
            supportingHint: true,
            userInstruction: userInstruction,
            runtimeNote: runtimeNote,
            directory: directory
        )
    }

    /// Format a loaded skill into a user-message payload (Hermes
    /// `_build_skill_message`).
    private static func buildSkillMessage(
        info: SkillCommandInfo,
        content: String,
        activationNote: String,
        supportingHint: Bool,
        userInstruction: String = "",
        runtimeNote: String = "",
        directory: URL? = nil
    ) -> String {
        var parts: [String] = [activationNote, "", content.trimmingCharacters(in: .whitespacesAndNewlines)]

        parts.append("")
        parts.append("[Skill directory: \(info.skillDir.path)]")
        parts.append("Resolve any relative paths in this skill (e.g. `scripts/foo.js`, `templates/config.yaml`) against that directory, then run them with the terminal tool using the absolute path.")

        if supportingHint {
            var supporting: [(rel: String, abs: String)] = []
            for sub in ["references", "templates", "scripts", "assets"] {
                let subDir = info.skillDir.appendingPathComponent(sub)
                guard let enumerator = FileManager.default.enumerator(
                    at: subDir, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let file as URL in enumerator {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue {
                        supporting.append((file.path.replacingOccurrences(of: info.skillDir.path + "/", with: ""), file.path))
                    }
                }
            }
            if !supporting.isEmpty {
                parts.append("")
                parts.append("[This skill has supporting files:]")
                for s in supporting.sorted(by: { $0.rel < $1.rel }) {
                    parts.append("- \(s.rel)  ->  \(s.abs)")
                }
                parts.append("")
                parts.append("Load any of these with skill_view(name=\"\(info.name)\", file_path=\"<path>\"), or run scripts directly by absolute path (e.g. `\(info.skillDir.path)/scripts/foo.js`).")
            }
        }

        if !userInstruction.isEmpty {
            parts.append("")
            parts.append("The user has provided the following instruction alongside the skill invocation: \(userInstruction)")
        }
        if !runtimeNote.isEmpty {
            parts.append("")
            parts.append("[Runtime note: \(runtimeNote)]")
        }
        return parts.joined(separator: "\n")
    }

    /// Consume additional leading `/skill` tokens from `rest` (the text after
    /// the first skill command), up to `maxStackedSkills` total leading skills.
    /// Returns `(extraCmdKeys, remainingInstruction)`.
    public static func splitStackedSkillCommands(_ rest: String, directory: URL? = nil) -> ([String], String) {
        let commands = getSkillCommands(directory: directory)
        var keys: [String] = []
        var remaining: [String] = []
        let tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for token in tokens {
            if keys.count < maxStackedSkills - 1, token.hasPrefix("/") {
                let key = "/" + token.dropFirst().replacingOccurrences(of: "_", with: "-")
                if commands[key] != nil {
                    keys.append(key)
                    continue
                }
            }
            remaining.append(token)
        }
        return (keys, remaining.joined(separator: " "))
    }

    /// Expand a chat message into its model-facing form when it begins with a
    /// skill slash command. Returns the expanded message, or `nil` when the
    /// message is not a skill invocation.
    public static func expandSlashCommand(_ text: String, directory: URL? = nil) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = tokens.first else { return nil }
        guard let key = resolveSkillCommandKey(first, directory: directory) else { return nil }
        let restStart = text.index(text.startIndex, offsetBy: first.count)
        let rest = String(text[restStart...]).trimmingCharacters(in: .whitespaces)
        let (extraKeys, userInstruction) = splitStackedSkillCommands(rest, directory: directory)
        if !extraKeys.isEmpty {
            return buildStackedSkillInvocationMessage([key] + extraKeys, userInstruction: userInstruction, directory: directory)?.message
        }
        return buildSkillInvocationMessage(key, userInstruction: userInstruction, directory: directory)
    }

    // MARK: Frontmatter `command:` support (existing API)

    /// Parse a `command:` frontmatter line (skill frontmatter may carry a
    /// short `command:` slug for slash-style invocation).
    public static func commandName(fromFrontmatter frontmatter: String) -> String? {
        for line in frontmatter.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("command:") {
                return l.dropFirst("command:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The invocation message appended to the agent's context when a command
    /// skill is activated.
    public static func invocationMessage(command: String, skillName: String) -> String {
        "\(invocationPrefix) \"\(command)\" skill. The full skill content is loaded below. Follow its instructions."
    }

    /// Preload prompt when the user typed `/<command>`.
    public static func preloadedLine(command: String, skillName: String) -> String {
        "/\(command) — invoking skill '\(skillName)'."
    }
}
