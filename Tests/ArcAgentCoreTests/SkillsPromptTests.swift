import Foundation
import Testing
@testable import ArcAgentCore

/// The `## Skills (mandatory)` block shared by the CLI harness and the webui
/// turn engine — identical framing keeps automatic skill loading consistent
/// on both surfaces (reference `SKILLS_GUIDANCE` parity).
@Suite("Skills prompt section")
struct SkillsPromptTests {

    @Test("section carries the mandatory framing and available_skills tags")
    func sectionShape() {
        let section = SkillsPrompt.section(index: "- `demo`: test")
        #expect(section.hasPrefix("## Skills (mandatory)"))
        #expect(section.contains("MUST load it with skill_view(name)"))
        #expect(section.contains("<available_skills>"))
        #expect(section.contains("</available_skills>"))
        #expect(section.contains("- `demo`: test"))
    }

    @Test("framing text matches the reference contract")
    func framingContract() {
        let f = SkillsPrompt.mandatoryFraming
        #expect(f.contains("scan the skills below"))
        #expect(f.contains("partial"))
        #expect(f.contains("Err on the side of loading"))
    }

    @Test("index composition follows the category + 57-char description format")
    func indexFormat() {
        let skill = Skill(
            name: "swift-testing-tests",
            description: "Use when writing Swift tests. Swift Testing, never XCTest.",
            content: "# x",
            category: "software-development",
            path: URL(fileURLWithPath: "/tmp/skills/swift-testing-tests/SKILL.md")
        )
        let idx = buildSkillsIndex([skill])
        #expect(idx.contains("### software-development"))
        #expect(idx.contains("swift-testing-tests"))
        #expect(idx.contains("Swift Testing, never XCTest."))
    }

    @Test("empty index says so, section still framed")
    func emptyIndex() {
        #expect(buildSkillsIndex([]) == "No skills available.")
        let section = SkillsPrompt.section(index: buildSkillsIndex([]))
        #expect(section.contains("<available_skills>"))
        #expect(section.contains("No skills available."))
    }

    @Test("pinned section carries every skill's full content")
    func pinnedSectionContent() {
        let a = Skill(name: "swift-testing-tests", description: "Write Swift tests.", content: "# Swift Testing\n\n```swift\n@Test\n```\n", path: URL(fileURLWithPath: "/tmp/a/SKILL.md"))
        let b = Skill(name: "git-branch-recovery", description: "Move git work.", content: "# Git Branch Recovery\n\ncommands here\n", path: URL(fileURLWithPath: "/tmp/b/SKILL.md"))
        let section = SkillsPrompt.pinnedSection(skills: [a, b])
        #expect(section.hasPrefix("## Pinned Profile Skills (always loaded)"))
        #expect(section.contains("ALWAYS in your context"))
        #expect(section.contains("### swift-testing-tests"))
        #expect(section.contains("# Swift Testing"))
        #expect(section.contains("### git-branch-recovery"))
        #expect(section.contains("commands here"))
    }

    @Test("pinned section preserves order and drops nothing")
    func pinnedSectionOrder() {
        let s = Skill(name: "x", description: "d", content: "c", path: URL(fileURLWithPath: "/tmp/x/SKILL.md"))
        let t = Skill(name: "y", description: "d", content: "c", path: URL(fileURLWithPath: "/tmp/y/SKILL.md"))
        let section = SkillsPrompt.pinnedSection(skills: [s, t])
        let x = section.range(of: "### x")!.lowerBound
        let y = section.range(of: "### y")!.lowerBound
        #expect(x < y)
    }
}
