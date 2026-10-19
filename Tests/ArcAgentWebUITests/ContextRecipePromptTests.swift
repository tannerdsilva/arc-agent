import Foundation
import Testing
@testable import ArcWebUI
@testable import ArcAgentCore

extension ArcWebUITestRoot {
    /// The web UI's prompt builder must honor the same per-session context
    /// recipe as the daemon/headless surfaces: the recipe is resolved through
    /// `ResolvedContextRecipe.resolve` (global defaults < profile defaults <
    /// session overrides), and each rendered segment is gated by it. This is
    /// the "Option A" reconciliation — the web UI drives the shared recipe
    /// layer instead of a hardcoded prompt, so the Context toggles affect the
    /// visible turns in the browser too.
    @Suite("Context recipe prompt", .serialized)
    struct ContextRecipePromptTests {

        @Test("web UI prompt resolves a per-session recipe")
        func resolvesRecipe() {
            let actions = Self.source("Actions.swift")
            #expect(actions.contains("resolveContextRecipe(for: sessionID)"))
            #expect(actions.contains("let on: (ContextSegment) -> Bool = { recipe.isEnabled($0) }"))
        }

        @Test("segments the web UI renders are gated")
        func segmentsGated() {
            let actions = Self.source("Actions.swift")
            #expect(actions.contains("if on(.skills)"))
            #expect(actions.contains("if on(.memory)"))
            #expect(actions.contains("if on(.userProfile)"))
            #expect(actions.contains("if on(.environment)"))
        }

        @Test("identity + SOUL stay on; the resolver merges global < profile < session")
        func resolverMerge() {
            let actions = Self.source("Actions.swift")
            // The SOUL preamble is identity, not a toggleable segment.
            #expect(actions.contains("let soul = p.soulMD, !soul.isEmpty"))
            // The resolver pulls the three tiers the same way SessionAgent does.
            #expect(actions.contains("global: settings.contextDefaults"))
            #expect(actions.contains("profile: boundProfile?.contextDefaults"))
            #expect(actions.contains("session: session?.contextOverrides"))
            #expect(actions.contains("ResolvedContextRecipe.resolve("))
        }

        @Test("recipe model and merge semantics are exercised at the core layer")
        func coreRecipeContract() {
            // The web UI delegates to the same core merge; assert the shared
            // resolution is reachable and tri-state here, mirroring the core
            // suite's contract at the surface that consumes it.
            let resolved = ResolvedContextRecipe.resolve(
                global: ContextRecipe(segments: [.memory: false]),
                profile: ContextRecipe(segments: [.skills: false]),
                session: ContextRecipe(segments: [.userProfile: false])
            )
            #expect(resolved.isEnabled(.memory) == false)
            #expect(resolved.isEnabled(.skills) == false)
            #expect(resolved.isEnabled(.userProfile) == false)
            #expect(resolved.isEnabled(.projectContext) == true)
            #expect(resolved.isEnabled(.environment) == true)
        }

        // MARK: - Helpers

        static func source(_ name: String) -> String {
            for base in ["Sources/ArcWebUI", "Sources/ArcAgentCore"] {
                if let s = try? String(contentsOfFile: "\(base)/\(name)", encoding: .utf8) {
                    return s
                }
            }
            return ""
        }
    }
}
