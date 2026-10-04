import Foundation

/// arc-parity skills injection into the system prompt.
///
/// Both the CLI harness (`ArcAgent`) and the webui turn engine build their
/// system prompt from this single block: the mandatory framing that tells the
/// model to scan and load matching skills, plus the `<available_skills>`
/// index (see ``buildSkillsIndex``). Keeping it in one place guarantees the
/// two surfaces cannot drift — the webui previously showed a bare
/// "Available skills:" list with no instruction to load, which is why it
/// re-derived conventions instead of pulling the matching audit skill.
public enum SkillsPrompt {

    /// Mandatory framing (reference `SKILLS_GUIDANCE` parity): scan, match, load.
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

    /// The `## Pinned profile skills` section: skills a profile pins into
    /// context, injected with their full SKILL.md content on every prompt.
    ///
    /// Equivalent to the user having loaded each skill explicitly — the model
    /// must treat them as mandatory instructions without having to scan first.
    public static func pinnedSection(skills: [Skill]) -> String {
        let framing =
            "The following skills are pinned to this profile and are ALWAYS in your context. "
            + "Follow their instructions exactly — no need to load them separately."
        let body = skills.map { skill in
            "### \(skill.name)\n\n\(skill.content)"
        }.joined(separator: "\n\n")
        return "## Pinned Profile Skills (always loaded)\n\n\(framing)\n\n\(body)"
    }
}
