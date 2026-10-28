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
    public nonisolated(unsafe) static var config: AgentPowersConfig = AgentPowersConfig()

    /// Where skills live (`~/.arc/skills` by default). Overridable for tests.
    public nonisolated(unsafe) static var skillsDirectory: URL = ArcHome.skills

    /// Install the gate from configuration. Installed once at startup by
    /// ``ArcDaemon`` (the daemon's agents, the CLI's agent and a hosted web UI
    /// all consult this one gate); ``ArcAgent`` re-asserts only a
    /// *non-default* config so a plainly-constructed agent never clobbers a
    /// lockdown; the web UI's toggles are the live writer.
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

    // MARK: Profile documents

    /// Capture the current gate as an immutable ``ToolGrant``.
    ///
    /// This is the bridge from the process-global switch to the value every
    /// authority-bearing tool takes. Construction sites call it once per agent
    /// (the daemon's session agents, the web UI's turn, the CLI) and hand the
    /// result to `buildRegistry(context:)`; the four computed `entry`
    /// properties that used to call it per access are being retired slice by
    /// slice. It must never be captured in a `static let` — the gate is
    /// reconfigured at runtime (the web UI's toggles, the tests), and a cached
    /// grant would go stale and keep exercising authority the operator has
    /// since revoked.
    ///
    /// The two locks map to two ``DocumentAccess`` cases, so "profile editing
    /// is off" and "all four documents are locked" stop sharing a refusal
    /// sentence (defect D1).
    public static func grant(profile: ProfileName) -> ToolGrant {
        let config = self.config
        let access: DocumentAccess
        if !config.profileEdit {
            access = .none
        } else if config.lockedProfileFiles.isEmpty {
            access = .all
        } else {
            access = .only(Set(ProfileFile.allCases.filter {
                !config.lockedProfileFiles.contains($0.rawValue)
            }))
        }
        return ToolGrant(
            profile: profile,
            documentAccess: access,
            mayManageSkills: config.skillsManage
        )
    }

    // MARK: Defense-in-depth path guard (write_file)

    /// Returns a refusal reason when `path` targets a locked surface, else nil.
    /// Used by general write tools so the dedicated tools are the ONLY way in
    /// while a lockdown is on.
    ///
    /// Document refusals come from a grant read *now* — this guard must track
    /// the live gate, not a value captured at startup, because the web UI's
    /// toggles rewrite it while a session is running.
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

        // The four profile documents, by name — the rule both this guard and
        // `ToolGrant.refusal(forPath:)` use.
        guard let document = ProfileFile.at(path: path) else { return nil }
        return grant(profile: .default).refusal(for: document)
    }
}
