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
            let global = ContextRecipe(segments: [.memory: false, .environment: false])
            let profile = ContextRecipe(segments: [.environment: true])
            let session = ContextRecipe(segments: [.skills: false])
            let resolved = ResolvedContextRecipe.resolve(global: global, profile: profile, session: session)

            #expect(resolved.isEnabled(.memory) == false)        // from global
            #expect(resolved.isEnabled(.environment) == true)    // profile beats global
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
            #expect(resolved.isEnabled(.environment) == true)    // default
        }

        @Test("a recipe round-trips through Codable")
        func codableRoundTrip() throws {
            let recipe = ContextRecipe(segments: [.environment: false, .memory: false, .personality: true], custom: ["custom note"])
            let data = try JSONEncoder().encode(recipe)
            let decoded = try JSONDecoder().decode(ContextRecipe.self, from: data)
            #expect(decoded == recipe)
            #expect(decoded.segments[.environment] == false)
            #expect(decoded.segments[.personality] == true)
            #expect(decoded.customItems == ["custom note"])
        }

        @Test("custom blocks are stitched into a single Custom Context section")
        func customBlocksStitched() async throws {
            let recipe = ResolvedContextRecipe(segments: [
                .projectContext: false, .personality: false,
            ], custom: ["First authored note.", "Second authored note."])
            let config = makeConfig(contextRecipe: recipe)
            let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
            let prompt = try await systemPrompt(config: config, box: box)

            #expect(prompt.contains("## Custom Context"))
            #expect(prompt.contains("First authored note."))
            #expect(prompt.contains("Second authored note."))
        }

        @Test("stitchCustom drops blanks and duplicates; nil when empty")
        func stitchCustomBehavior() {
            #expect(ContextRecipe.stitchCustom([""]) == nil)
            #expect(ContextRecipe.stitchCustom(["  ", "\n"]) == nil)
            #expect(ContextRecipe.stitchCustom(["alpha", "beta"]) == ["alpha", "beta"])
            #expect(ContextRecipe.stitchCustom(["alpha", "  ", "alpha", "beta"]) == ["alpha", "beta"])
            #expect(ContextRecipe.stitchCustom([" a ", "a"]) == ["a"], "trim then dedupe")
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
                .skills: false, .environment: false,
                .personality: false, .timestamp: false, .projectContext: false,
            ])
            let config = makeConfig(contextRecipe: recipe, injectProjectContext: true)
            let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
            let prompt = try await systemPrompt(config: config, box: box)

            #expect(prompt.contains("You are ARC Agent"), "identity must remain")
            #expect(prompt.contains("## Available Tools"), "tools index is always on (no prompt-only toggle)")
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

        // MARK: - Full per-segment matrix

        /// The prose marker that identifies each segment's region of the prompt.
        /// Every marker is unique to its segment, so presence/absence is
        /// unambiguous when toggling.
        private func marker(for seg: ContextSegment) -> String {
            switch seg {
            case .memory: return "## Memory (Your Persistent Notes)"
            case .userProfile: return "## User Profile"
            case .skills: return "## Skills (mandatory)"
            case .projectContext: return "## Workspace & Project Context"
            case .environment: return "## Environment"
            case .guidance: return "## Finishing the job"
            case .personality: return "## Personality"
            case .timestamp: return "Conversation started:"
            }
        }

        private func makeFullConfig(recipe: ResolvedContextRecipe, disabledToolsets: Set<String> = []) throws -> ArcAgent.Configuration {
            var registry = CompileTimeToolRegistry()
            try? registry.register(SkillViewTool.entry)

            let memDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-ctx-mem-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
            try "persistent test memory note".write(to: memDir.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
            try "user profile test".write(to: memDir.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)

            let projDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-ctx-proj-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
            try "# AGENTS\ncontext marker".write(to: projDir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

            return ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "sk-test",
                registry: registry,
                sessionStore: tempStore(),
                memoryProvider: FileMemoryProvider(directory: memDir),
                skills: [defaultSkill()],
                maxIterations: 10,
                maxTurnDuration: 30,
                persistSessions: false,
                approvalMode: .off,
                query: nil,
                maxContextTokens: 64_000,
                personalityPrompt: "Be terse.",
                sessionID: "ctx-full",
                injectProjectContext: true,
                contextDirectory: projDir,
                disabledToolsets: disabledToolsets,
                contextRecipe: recipe
            )
        }

        /// Every segment is individually toggled off and asserted absent, while
        /// every other segment stays present — proving the switches are
        /// independent (no off-by-one, no deselect-adjacent regressions).
        @Test("each segment individually disabled removes only its own marker")
        func eachDisabledRemovesOnlyItsMarker() async throws {
            for seg in ContextSegment.allCases {
                let recipe = ResolvedContextRecipe(segments: [seg: false])
                let config = try makeFullConfig(recipe: recipe)
                let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
                let prompt = try await systemPrompt(config: config, box: box)

                #expect(!prompt.contains(marker(for: seg)),
                        "disabled \(seg) should be absent from the prompt")
                for other in ContextSegment.allCases where other != seg {
                    #expect(prompt.contains(marker(for: other)),
                            "enabled \(other) should remain when only \(seg) is off")
                }
            }
        }

        /// Turning every switch off must leave only the untoggleable identity
        /// and rules core — no segment marker may leak through.
        @Test("all segments disabled leaves only identity and rules")
        func allDisabledOnlyCore() async throws {
            let recipe = ResolvedContextRecipe(all: false)
            let config = try makeFullConfig(recipe: recipe)
            let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
            let prompt = try await systemPrompt(config: config, box: box)

            #expect(prompt.contains("You are ARC Agent"), "identity must remain")
            for seg in ContextSegment.allCases {
                #expect(!prompt.contains(marker(for: seg)),
                        "\(seg) must be absent when all switches are off")
            }
        }

        /// With every switch on, all nine segments are present — the positive
        /// control for the matrix (and proof the full-config harness itself
        /// is set up to render every region).
        @Test("all segments enabled includes every marker")
        func allEnabledIncludesEveryMarker() async throws {
            let recipe = ResolvedContextRecipe(all: true)
            let config = try makeFullConfig(recipe: recipe)
            let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
            let prompt = try await systemPrompt(config: config, box: box)

            for seg in ContextSegment.allCases {
                #expect(prompt.contains(marker(for: seg)),
                        "enabled \\(seg) should be present")
            }
        }

        /// The "Available Tools" prose index is always included (there is no
        /// prompt-only tools toggle). It must never remove the function-calling
        /// schemas handed to the model, so a chat can still recognise and call
        /// tools.
        @Test("tools index always present and schemas reach the model")
        func toolsIndexAlwaysPresentAndSchemasReachModel() async throws {
            let recipe = ResolvedContextRecipe(segments: [.skills: false, .environment: false])
            let config = try makeFullConfig(recipe: recipe)
            let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
            let prompt = try await systemPrompt(config: config, box: box)

            #expect(prompt.contains("## Available Tools"),
                    "the tools prose index must always be present")

            let schemas = box.recordedTools().first ?? nil
            #expect(schemas != nil && !schemas!.isEmpty,
                    "tool schemas must still be sent to the model")
            #expect(schemas!.contains { ($0["function"] as? [String: Any])?["name"] as? String == "skill_view" },
                    "a registered tool's schema must remain available")
        }

        /// The real off-switch for tools is disabledToolsets: it removes the
        /// schemas from the model request entirely, so the model cannot call
        /// a disabled toolset's tools.
        @Test("disabledToolsets removes tool schemas from the model request")
        func disabledToolsetsRemovesSchemas() async throws {
            let recipe = ResolvedContextRecipe(all: true)
            let config = try makeFullConfig(recipe: recipe, disabledToolsets: ["core"])
            let box = ClientScripts(responses: [LLMResponse(content: "ok", finishReason: "stop")])
            _ = try await systemPrompt(config: config, box: box)

            // With the only registered toolset disabled, no leading request
            // may advertise skill_view. (tools may be nil, empty, or non-empty.)
            let requests = box.recordedTools()
            #expect(!requests.isEmpty, "at least one model request must be made")
            let names = requests.flatMap { ($0 ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String } }
            #expect(!names.contains("skill_view"),
                    "a disabled toolset's tool must be removed from the schemas")
        }
    }
}
