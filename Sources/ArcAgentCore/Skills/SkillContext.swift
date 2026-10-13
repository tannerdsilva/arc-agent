import Foundation

// MARK: - Per-turn skill context (TaskLocal)

/// Task-local context set by the agent turn entry points so tool handlers
/// (``SkillViewTool``) can access the owning session without a static
/// cross-agent race. Mirror of ``WorkspacePath``'s TaskLocal anchoring.
public enum SkillContext {
    /// Session ID of the turn currently executing (nil for non-agent callers).
    @TaskLocal public static var sessionID: String? = nil

    /// Whether ``SkillPreprocessing`` may run inline `!`cmd`` shell blocks.
    /// Off by default; the agent turn sets it from config
    /// (`agent.skill_inline_commands`).
    @TaskLocal public static var allowInlineCommands: Bool = false
}
