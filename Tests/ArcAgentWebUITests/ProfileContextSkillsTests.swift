import Foundation
import Testing
@testable import ArcWebUI
@testable import ArcAgentCore

/// Profile-scoped "context skills": skills pinned to a profile whose full
/// SKILL.md content is injected into every prompt of chats bound to it.
@Suite("Profile context skills")
struct ProfileContextSkillsTests {

    // MARK: - Source contracts

    @Test("profile model carries contextSkills")
    func profileModel() {
        let src = Self.source("Profile.swift") // resolves under ArcAgentCore/Profile/
        #expect(src.contains("contextSkills: [String]?"))
        #expect(src.contains("pinned to this profile"))
    }

    @Test("prompt builder injects the pinned section")
    func promptInjection() {
        let actions = Self.source("Actions.swift")
        #expect(actions.contains("SkillsPrompt.pinnedSection"))
        #expect(actions.contains("p.contextSkills, !pinned.isEmpty"))
        let promptSrc = Self.source("SkillsPrompt.swift") // resolves under ArcAgentCore/Skills/
        #expect(promptSrc.contains("pinnedSection"))
        #expect(promptSrc.contains("Pinned Profile Skills"))
    }

    @Test("profile edit form renders the context skills section")
    func formSection() {
        let views = Self.source("Views.swift")
        #expect(views.contains("Context skills"))
        #expect(views.contains("profileContextSkillsHTML()"))
        #expect(views.contains("pcs-toggle"))
        #expect(views.contains("data-component-id=\"pcs\""))
        #expect(views.contains("data-component-id=\"pcs-rm\""))
    }

    @Test("profile wires cover picker add/remove/save")
    func wires() {
        let actions = Self.source("Actions.swift")
        #expect(actions.contains("id: \"pcs-toggle\""))
        #expect(actions.contains("id: \"pcs\""))
        #expect(actions.contains("id: \"pcs-rm\""))
        #expect(actions.contains("tid.hasPrefix(\"pcs-pick-\")"))
        #expect(actions.contains("profileSkillsDraft"))
        #expect(actions.contains("p.contextSkills = contextSkills"))
    }

    // MARK: - Helpers

    static func source(_ name: String) -> String {
        for base in ["Sources/ArcWebUI", "Sources/ArcAgentCore", "Sources/ArcAgentCore/Profile", "Sources/ArcAgentCore/Skills"] {
            if let s = try? String(contentsOfFile: "\(base)/\(name)") {
                return s
            }
        }
        return ""
    }
}
