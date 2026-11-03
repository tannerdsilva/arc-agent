import Testing
@testable import ArcAgentCore

/// Hermes parity for the context-breakdown pane: `splitPromptSections` pulls
/// the skills index, rules, and memory blocks out of the system prompt the way
/// `agent/context_breakdown.py`'s `_SKILLS_BLOCK_RE` extraction does upstream.
@Suite("context breakdown section split")
struct ContextBreakdownSectionSplitTests {

    private let sample = """
    # Identity

    You are ARC Agent.

    ## Environment

    - OS: macOS

    ## Workspace & Project Context

    ### AGENTS.md

    Some rules. Note this inner line is not a section: ## not-a-header? no,
    mid-line hashes do not open sections.

    ## Skills (mandatory)

    Load a skill with skill_view.

    <available_skills>
      - alpha: does a thing
      - beta: does another
    </available_skills>

    ## Memory (Your Persistent Notes)

    § a memory entry

    ## User Profile

    § a user fact

    ## Personality

    Be direct.
    """

    @Test("skills index, rules, and memory each land in their own block")
    func sectionsAreExtracted() {
        let out = ArcAgent.splitPromptSections(sample, headers: [
            "## Workspace & Project Context",
            "## Skills (mandatory)",
            "## Memory (Your Persistent Notes)",
            "## User Profile",
        ])
        #expect(out["## Skills (mandatory)"]?.contains("<available_skills>") == true)
        #expect(out["## Skills (mandatory)"]?.contains("- alpha: does a thing") == true)
        #expect(out["## Workspace & Project Context"]?.contains("### AGENTS.md") == true)
        #expect(out["## Memory (Your Persistent Notes)"]?.contains("§ a memory entry") == true)
        #expect(out["## User Profile"]?.contains("§ a user fact") == true)
    }

    @Test("the remainder keeps identity, environment, and personality")
    func remainderKeepsTheRest() {
        let out = ArcAgent.splitPromptSections(sample, headers: ["## Skills (mandatory)"])
        let rest = out["__remainder__"] ?? ""
        #expect(rest.contains("You are ARC Agent."))
        #expect(rest.contains("## Environment"))
        #expect(rest.contains("## Personality"))
        // the extracted block is gone from the remainder
        #expect(!rest.contains("<available_skills>"))
    }

    @Test("triple-hash subheaders stay inside their section")
    func subheadersDoNotTerminate() {
        let out = ArcAgent.splitPromptSections(sample, headers: ["## Workspace & Project Context"])
        let rules = out["## Workspace & Project Context"] ?? ""
        #expect(rules.contains("### AGENTS.md"))
        #expect(rules.contains("Some rules."))
    }

    @Test("absent headers yield nothing and lose nothing")
    func absentHeadersAreHarmless() {
        let out = ArcAgent.splitPromptSections("Hello\n\n## World\n\nBody", headers: ["## Skills (mandatory)"])
        #expect(out["## Skills (mandatory)"] == nil)
        #expect(out["__remainder__"]?.contains("## World") == true)
        #expect(out["__remainder__"]?.contains("Body") == true)
    }

    @Test("mid-line hashes never open a section")
    func inlineHashesAreInert() {
        let text = "text with ## inline hash stays whole"
        let out = ArcAgent.splitPromptSections(text, headers: ["## inline hash"])
        #expect(out["## inline hash"] == nil)
        #expect(out["__remainder__"] == text)
    }
}
