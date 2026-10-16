import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

extension ArcCoreTestRoot {
    /// Context-recipe tests: the tri-state global < profile < session merge,
    /// and the segment toggles that include/exclude regions of the system prompt.
    @Suite("Context Recipe", .serialized)
    struct ContextRecipeTests {

        // MARK: - Merge & tri-state semantics

        @Test("no overrides leave every segment enabled")
        func noOverridesAllOn() {
            let resolved = ResolvedContextRecipe.resolve()
            for seg in ContextSegment.allCases {
                #expect(resolved.isEnabled(seg) == true, "segment \(seg) should default on")
            }
        }

        @Test("merge resolves global < profile < session precedence per segment")
        func mergePrecedence() {
            let global = ContextRecipe(segments: [.memory: false, .tools: false])
            let profile = ContextRecipe(segments: [.tools: true])
            let session = ContextRecipe(segments: [.skills: false])
            let resolved = ResolvedContextRecipe.resolve(global: global, profile: profile, session: session)

            #expect(resolved.isEnabled(.memory) == false)        // from global
            #expect(resolved.isEnabled(.tools) == true)          // profile beats global
            #expect(resolved.isEnabled(.skills) == false)        // from session
            #expect(resolved.isEnabled(.userProfile) == true)    // default
            #expect(resolved.isEnabled(.timestamp) == true)      // default
            #expect(resolved.isEnabled(.environment) == true)    // default
        }

        @Test("deepest non-nil override wins")
        func deepestWins() {
            let profile = ContextRecipe(segments: [.guidance: false, .personality: false])
            let session = ContextRecipe(segments: [.personality: true])
            let resolved = ResolvedContextRecipe.resolve(global: nil, profile: profile, session: session)

            #expect(resolved.isEnabled(.guidance) == false)      // from profile
            #expect(resolved.isEnabled(.personality) == true)    // session beats profile
            #expect(resolved.isEnabled(.tools) == true)          // default
        }

        @Test("a recipe round-trips through Codable")
        func codableRoundTrip() throws {
            let recipe = ContextRecipe(segments: [.tools: false, .memory: false, .personality: true])
            let data = try JSONEncoder().encode(recipe)
            let decoded = try JSONDecoder().decode(ContextRecipe.self, from: data)
            #expect(decoded == recipe)
            #expect(decoded.segments[.tools] == false)
            #expect(decoded.segments[.personality] == true)
        }

        // MARK: - Prompt segment toggles

        private func tempStore() -> FileSessionStore {
            FileSessionStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("arc-context-recipe-\\(UUID().uuidString)")
            )
        }

        private func defaultSkill() -> Skill {
            Skill(
                name: "alpha",
                description: "first skill description",
                content: "c",
                category: "dev",
                path: FileManager.default.temporaryDirectory
                    .appendingPathComponent("arc-context-skill-\\(UUID().uuidString)")
            )
        }

        private func makeConfig(
            contextRecipe: ResolvedContextRecipe? = nil,
            injectProjectContext: Bool = false,
            personalityPrompt: String = "Be terse.",
            skills: [Skill] = []
        ) -> ArcAgent.Configuration {
            // Register the skill loader so the skills section can render; without
            // it the prompt never advertises skills (and the toggles have nothing
            // to show/hide).
            var registry = CompileTimeToolRegistry()
            try? registry.register(SkillViewTool.entry)
            return ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "test",
                registry: registry,
                sessionStore: tempStore(),
                memoryProvider: nil,
                skills: skills.isEmpty ? [defaultSkill()] : skills,
                maxIterations: 10,
                maxTurnDuration: 30,
                persistSessions: false,
                approvalMode: .off,
                query: nil,
                maxContextTokens: 64_000,
                personalityPrompt: personalityPrompt,
                sessionID: "ctx-test",
                injectProjectContext: injectProjectContext,
                contextRecipe: contextRecipe
            )
        }

        private func systemPrompt(
            config: ArcAgent.Configuration,
            box: ClientScripts
        ) async throws -> String {
            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            defer { _ = httpClient.shutdown() }
            let agent = ArcAgent(config: config)
            await agent.setupClient(httpClient: httpClient)
            await agent.setClient(ScriptedClient(box: box))
            _ = try await agent.runConversation(message: "hello")
            return box.recordedCalls().first?
                .first(where: { $0.role == .system })?.content ?? ""
        }

        @Test("default recipe includes every standard segment")
        func defaultIncludesSegments() async throws {
            let config = makeConfig()
            let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
            let prompt = try await systemPrompt(config: config, box: box)

            #expect(prompt.contains("You are ARC Agent"))
            #expect(prompt.contains("## Available Tools"))
            #expect(prompt.contains("## Skills (mandatory)"))
            #expect(prompt.contains("## Environment"))
            #expect(prompt.contains("## Personality"))
            #expect(prompt.contains("Conversation started:"))
        }

        @Test("disabling segments removes them from the system prompt")
        func disabledSegmentsAbsent() async throws {
            let recipe = ResolvedContextRecipe(segments: [
                .tools: false, .skills: false, .environment: false,
                .personality: false, .timestamp: false, .projectContext: false,
            ])
            let config = makeConfig(contextRecipe: recipe, injectProjectContext: true)
            let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
            let prompt = try await systemPrompt(config: config, box: box)

            #expect(prompt.contains("You are ARC Agent"), "identity must remain")
            #expect(!prompt.contains("## Available Tools"))
            #expect(!prompt.contains("## Skills (mandatory)"))
            #expect(!prompt.contains("## Environment"))
            #expect(!prompt.contains("## Personality"))
            #expect(!prompt.contains("## Workspace & Project Context"))
            #expect(!prompt.contains("Conversation started:"))
        }

        @Test("toggling segments independently leaves the others intact")
        func togglesAreIndependent() async throws {
            // Only disable project context + personality; everything else stays.
            let recipe = ResolvedContextRecipe(segments: [.projectContext: false, .personality: false])
            let config = makeConfig(contextRecipe: recipe)
            let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
            let prompt = try await systemPrompt(config: config, box: box)

            #expect(!prompt.contains("## Personality"))
            #expect(prompt.contains("## Available Tools"))
            #expect(prompt.contains("## Skills (mandatory)"))
            #expect(prompt.contains("## Environment"))
            #expect(prompt.contains("Conversation started:"))
        }
    }
}
