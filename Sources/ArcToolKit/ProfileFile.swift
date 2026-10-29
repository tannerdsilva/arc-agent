// MARK: - ProfileFile
//
// The four documents a profile owns. Raw values are the strings the gate,
// the settings UI and `AgentPowersConfig.lockedProfileFiles` already use, and
// the refusal sentences uppercase them (`MEMORY`, `USER`, `SOUL`, `AGENTS`),
// so they must not drift.

/// One of the four documents belonging to a profile.
public enum ProfileFile: String, Sendable, Hashable, CaseIterable {

    /// The agent's persistent notes (`MEMORY.md`).
    case memory = "memory"

    /// The user profile (`USER.md`).
    case user = "user"

    /// The profile persona/prompt (`SOUL.md`).
    case soul = "soul"

    /// The workspace agent instructions (`AGENTS.md`).
    case agents = "agents"

    /// The on-disk file name for this document.
    public var fileName: String {
        switch self {
        case .memory: return "MEMORY.md"
        case .user: return "USER.md"
        case .soul: return "SOUL.md"
        case .agents: return "AGENTS.md"
        }
    }

    /// The name the operator-facing refusal sentences use.
    public var displayName: String { rawValue.uppercased() }

    /// The document a path names, or `nil` when it names something else.
    ///
    /// Matches on the last path component only — the rule the write guard has
    /// always used (`AgentPowers.blockedWriteReason(path:)`), which is also
    /// what makes it usable on a shell command that contains a path.
    public static func at(path: String) -> ProfileFile? {
        switch basename(path) {
        case "MEMORY.md":
            return .memory
        case "USER.md":
            return .user
        case "SOUL.md":
            return .soul
        case "AGENTS.md", ".reference.md", "CLAUDE.md", ".cursorrules":
            return .agents
        default:
            return nil
        }
    }

    /// Last path component, without Foundation.
    static func basename(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
