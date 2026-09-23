import Foundation

/// Hermes-parity skills injection into the system prompt.
///
/// Both the CLI harness (`ArcAgent`) and the webui turn engine build their
/// system prompt from this single block: the mandatory framing that tells the
/// model to scan and load matching skills, plus the `<available_skills>`
/// index (see ``buildSkillsIndex``). Keeping it in one place guarantees the
/// two surfaces cannot drift — the webui previously showed a bare
/// "Available skills:" list with no instruction to load, which is why it
/// re-derived conventions instead of pulling the matching audit skill.
public enum SkillsPrompt {

    /// Mandatory framing (Hermes `SKILLS_GUIDANCE` parity): scan, match, load.
    public static let mandatoryFraming =
        "Before replying, scan the skills below. If a skill matches or is even partially "
        + "relevant to your task, you MUST load it with skill_view(name) and follow its "
        + "instructions. Err on the side of loading — it is always better to have context "
        + "you don't need than to miss critical steps, pitfalls, or established workflows. "
        + "Skills contain specialized knowledge — API endpoints, tool-specific commands, "
        + "and proven workflows that outperform general-purpose approaches."

    /// The full `## Skills (mandatory)` section, ready to append to a system
    /// prompt.
    public static func section(index: String) -> String {
        "## Skills (mandatory)\n\n\(mandatoryFraming)\n\n<available_skills>\n\(index)\n</available_skills>"
    }
}
