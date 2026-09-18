import Foundation

// MARK: - Agent powers (runtime lockdown gate)
//
// The single in-process gate consulted by every mutation path: the dedicated
// skill/profile tools (source of truth) AND the general write tools
// (defense in depth — when a lockdown is on, `write_file`/`terminal` refuse
// writes that target the locked surfaces so the dedicated tools are the only
// way in). Configured from `AgentPowersConfig` (loaded from
// `~/.arc/config.json`) at agent startup; the webui toggles rewrite that file
// and the next agent start picks the gate up.

public enum AgentPowers {

    /// Live configuration, set by ``configure(_:)`` at agent startup.
    public static var config: AgentPowersConfig = AgentPowersConfig()

    /// Where skills live (`~/.arc/skills` by default). Overridable for tests.
    public static var skillsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".arc/skills")

    /// Where MEMORY.md / USER.md live (`~/.arc/memories` by default).
    public static var memoriesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".arc/memories")

    /// Install the gate from configuration. Called by ``ArcAgent`` at init.
    public static func configure(_ config: AgentPowersConfig) {
        self.config = config
    }

    // MARK: Skills

    public static func canManageSkills() -> Bool {
        config.skillsManage
    }

    public static func skillIsLocked(_ name: String) -> Bool {
        config.lockedSkills.contains(name)
    }

    /// The refusal reason for creating/editing a skill, or nil when allowed.
    public static func skillWriteRefusal(name: String) -> String? {
        if !config.skillsManage {
            return "Refused: skill creation/editing is locked in Settings (Agent powers → Skills). "
                + "The agent cannot create or edit skills while 'Agent can create/edit skills' is off."
        }
        if skillIsLocked(name) {
            return "Refused: skill '\(name)' is locked in Settings (Agent powers → Skills). "
                + "Unlock it there before editing."
        }
        return nil
    }

    // MARK: Profile files

    /// The refusal reason for writing a profile file, or nil when allowed.
    /// `file` is one of "memory", "user", "soul", "agents".
    public static func profileWriteRefusal(file: String) -> String? {
        if !config.profileEdit {
            return "Refused: profile editing is locked in Settings (Agent powers → Profile). "
                + "The agent cannot modify MEMORY/USER/SOUL/AGENTS while 'Agent can edit profile' is off."
        }
        if config.lockedProfileFiles.contains(file) {
            return "Refused: \(file.uppercased()) is locked in Settings (Agent powers → Profile). "
                + "Unlock it there before editing."
        }
        return nil
    }

    // MARK: Defense-in-depth path guard (write_file / terminal)

    /// Returns a refusal reason when `path` targets a locked surface, else nil.
    /// Used by general write tools so the dedicated tools are the ONLY way in
    /// while a lockdown is on.
    public static func blockedWriteReason(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let skillBase = skillsDirectory.resolvingSymlinksInPath().path
        let fullPath = url.resolvingSymlinksInPath().path

        // Skills directory tree.
        if fullPath.hasPrefix(skillBase + "/") || fullPath == skillBase {
            if !config.skillsManage {
                return "Refused: writes under the skills directory are locked in Settings "
                    + "(Agent powers → Skills). Use skill_creation / skill_edit while unlocked."
            }
            let relative = String(fullPath.dropFirst(skillBase.count))
            let components = relative.split(separator: "/").map(String.init)
            // Any write under a locked skill's directory.
            if let first = components.first, !first.isEmpty, skillIsLocked(first) {
                return "Refused: skill '\(first)' is locked in Settings "
                    + "(Agent powers → Skills). Use skill_edit after unlocking."
            }
            return nil
        }

        let name = url.lastPathComponent
        switch name {
        case "MEMORY.md":
            return profileWriteRefusal(file: "memory")
        case "USER.md":
            return profileWriteRefusal(file: "user")
        case "SOUL.md":
            return profileWriteRefusal(file: "soul")
        case "AGENTS.md", ".hermes.md", "CLAUDE.md", ".cursorrules":
            return profileWriteRefusal(file: "agents")
        default:
            return nil
        }
    }
}
