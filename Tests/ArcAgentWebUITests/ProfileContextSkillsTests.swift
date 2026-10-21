import Foundation
import Testing
@testable import ArcWebUI
@testable import ArcAgentCore

extension ArcWebUITestRoot {
    /// Profile-scoped "context skills": skills pinned to a profile whose full
    /// SKILL.md content is injected into every prompt of chats bound to it.
    @Suite("Profile context skills", .serialized)
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
        func formSection() async {
            // rendered, not grepped: the picker is a view tree now, so the only
            // honest question is whether the wiring attributes reached the DOM.
            var f = AppState.RenderFixture()
            f.profiles = [Profile(name: "fast", title: "Fast", description: "Quick answers",
                                  model: "gpt-5-mini")]
            f.editingProfile = "fast"
            let page = await AppState(renderFixture: f).profilesMain().markup.html
            #expect(page.contains("Context skills"), "the section keeps its heading")
            #expect(page.contains("id=\"pcs-toggle\""), "the picker has its trigger")
            #expect(page.contains("data-component-id=\"pcs\""),
                    "the popover is wired by component id — a class-only marker never fires")
            #expect(page.contains("data-component-id=\"pcs-rm\""),
                    "the remove row is wired by component id")
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
                if let s = try? String(contentsOfFile: "\(base)/\(name)", encoding: .utf8) {
                    return s
                }
            }
            return ""
        }
    }
}
