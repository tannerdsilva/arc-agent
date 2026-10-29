import Foundation
import Testing
@testable import ArcWebUI
import ArcAgentCore

// ===========================================================================
// MARK: - per-turn agent factory (CONVERGE A5, §4 T5)
//
// `AppState.makeTurnAgent` mints the agent a UI turn will run through. These
// tests pin every `Configuration` field the card names, plus the sources the
// plan's T5 list adds (preset + profile context, workspace, skills, memory,
// approval, auxiliary, moa, tool search, agent powers, background review,
// verify-on-stop). Nothing dispatches through the factory yet — A7 does the
// transplant.
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("turn agent factory", .serialized)
    struct TurnAgentFactoryTests {

        // the stub preset the card calls for: no network, every sampling knob
        // set so the profile override is observable.
        private static let preset = ModelConfigPreset(
            name: "a5-stub",
            model: "stub-model-1",
            provider: "custom",
            baseURL: "http://127.0.0.1:9/v1",
            apiKey: "stub-key",
            contextLength: 8_000,
            maxOutputTokens: 512,
            temperature: 0.2,
            topP: 0.5
        )

        /// the profile's context overrides — the caller's `profileContext`.
        private static let alphaContext = ProfileContextConfig(
            contextLength: 32_000,
            maxOutputTokens: 256,
            reasoningEffort: "high",
            temperature: 0.9,
            topP: 0.8,
            compressionBudget: 12_000
        )

        private static func temporaryWorkspace(_ label: String) -> String {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-a5-\(label)-\(UUID().uuidString)", isDirectory: true)
                .path
        }

        private static func skill(_ name: String) -> Skill {
            Skill(
                name: name,
                description: "\(name) fixture skill",
                content: "# \(name)",
                path: URL(fileURLWithPath: "/tmp/a5-skills/\(name)")
            )
        }

        /// a state bound to a profile that carries every knob the factory reads:
        /// a per-session workspace, a profile skills override, disabled
        /// toolsets, smart approval, a tool-loop cap, verify-on-stop and a
        /// background-review cadence.
        private func boundState(workspacePath: String) -> AppState {
            var f = AppState.RenderFixture()
            f.settings.workspaces = [
                WorkspaceEntry(
                    name: "main",
                    path: Self.temporaryWorkspace("main")
                ),
                WorkspaceEntry(name: "a5", path: workspacePath),
            ]
            f.settings.activeWorkspace = "main"
            f.settings.sessionWorkspaces["s-alpha"] = "a5"
            f.settings.sessionProfile["s-alpha"] = "alpha"
            f.settings.disabledSkills = ["alpha-off", "global-off"]
            f.settings.profileSkills["alpha"] = ["alpha-off"]
            f.settings.disabledToolsets = ["browser", "cron"]
            f.skills = [
                Self.skill("alpha-off"),
                Self.skill("global-off"),
                Self.skill("kept"),
            ]
            f.memory = StubMemoryProvider(marker: "stub-memory")
            f.profiles = [
                Profile(
                    name: "alpha",
                    title: "Alpha",
                    description: "factory fixture",
                    soulMD: "You are Alpha, the factory fixture.",
                    context: Self.alphaContext
                )
            ]
            f.arcConfig.security.approvalMode = "smart"
            f.arcConfig.guardrails.toolLoopCap = 7
            f.arcConfig.agent.verifyOnStop = true
            f.arcConfig.agent.backgroundReviewAfter = 5
            f.arcConfig.agent.backgroundReviewWindow = 3
            f.registryTools = [StubTool(name: "a5-probe", toolset: "test")]
            return AppState(renderFixture: f)
        }

        /// a state with no profile and no per-session bindings.
        private func plainState(workspacePath: String) -> AppState {
            var f = AppState.RenderFixture()
            f.settings.workspaces = [WorkspaceEntry(name: "main", path: workspacePath)]
            f.settings.activeWorkspace = "main"
            f.settings.disabledSkills = ["global-off"]
            f.settings.disabledToolsets = ["browser"]
            f.skills = [Self.skill("global-off"), Self.skill("kept")]
            return AppState(renderFixture: f)
        }

        // MARK: - the card's step 1 field list

        @Test("configuration carries the turn's session, workspace and turn-policy fields")
        func configurationCarriesTurnFields() async throws {
            let workspace = Self.temporaryWorkspace("alpha")
            let app = boundState(workspacePath: workspace)

            let (agent, config) = await app.makeTurnAgent(
                preset: Self.preset,
                profileContext: Self.alphaContext,
                thinking: "medium",
                headless: false,
                sessionID: "s-alpha"
            )
            _ = agent

            // the session + the transcript contract (§3.3: the UI is the only
            // writer, so the agent must not persist and must not compress).
            #expect(config.sessionID == "s-alpha")
            #expect(config.persistSessions == false)
            #expect(config.autoCompression == false)

            // the per-session workspace is both the tool root and the
            // project-context directory.
            let expectedRoot = await app.workspacePath(for: "s-alpha")
            #expect(expectedRoot == workspace)
            #expect(config.workspaceRoot == expectedRoot)
            #expect(config.contextDirectory?.path == expectedRoot)
            #expect(config.injectProjectContext == true)

            // the turn's own identity and budget.
            #expect(config.platformHint == "webui")
            #expect(config.maxIterations == AppState.effectiveMaxTurns())
            #expect(config.maxTurnDuration == 0,
                    "unlimited by default (agent.max_turn_duration unset → 0)")
            #expect(config.disabledToolsets == Set(["browser", "cron"]))
            let turnBudget = await app.compressionBudget(for: "s-alpha")
            #expect(turnBudget == 12_000, "the profile's compression budget")
            #expect(config.maxContextTokens == turnBudget)

            // the effective preset: profile context wins over the preset.
            #expect(config.model == "stub-model-1")
            #expect(config.provider == "custom")
            #expect(config.baseURL.absoluteString == "http://127.0.0.1:9/v1")
            #expect(config.apiKey == "stub-key")
            #expect(config.contextLength == 32_000)
            #expect(config.maxOutputTokens == 256)
            #expect(config.temperature == 0.9)
            #expect(config.topP == 0.8)
            #expect(config.reasoningEffort == "high")

            // the profile's skills override replaces the global disabled list:
            // "global-off" survives because the profile only disabled
            // "alpha-off".
            #expect(config.skills.map(\.name) == ["global-off", "kept"])

            // the shared registry, memory provider and security/routing blocks.
            #expect(config.registry.lookup(name: "a5-probe") != nil)
            let memory = try await config.memoryProvider?.readMemory()
            #expect(memory == "stub-memory")
            #expect(config.approvalMode == .smart)
            #expect(config.toolLoopCap == 7)
            #expect(config.verifyOnStop == true)
            #expect(config.backgroundReview.afterToolCalls == 5)
            #expect(config.backgroundReview.window == 3)

            let arc = await app.arcConfig
            #expect(config.auxiliary == arc.auxiliary)
            #expect(config.moa == arc.moa)
            #expect(config.toolSearch == arc.toolSearch)
            #expect(config.agentPowers == arc.agentPowers)
        }

        // MARK: - fallbacks when nothing is bound

        @Test("without a profile the thinking level and global disabled sets win")
        func configurationFallsBackToSessionDefaults() async throws {
            let workspace = Self.temporaryWorkspace("plain")
            let app = plainState(workspacePath: workspace)

            let (_, config) = await app.makeTurnAgent(
                preset: Self.preset,
                profileContext: nil,
                thinking: "off",
                headless: true,
                sessionID: "s-plain"
            )

            #expect(config.sessionID == "s-plain")
            #expect(config.workspaceRoot == workspace)
            #expect(config.reasoningEffort == nil, "off means no reasoning effort")
            #expect(config.skills.map(\.name) == ["kept"])
            #expect(config.contextLength == 8_000, "the preset's own window is kept")
            #expect(config.maxOutputTokens == 512)
            #expect(config.temperature == 0.2)
            #expect(config.topP == 0.5)
            #expect(config.approvalMode == .manual, "ArcConfig's default approval mode")
            #expect(config.disabledToolsets == Set(["browser"]))
            let defaultBudget = await app.compressionBudget(for: "s-plain")
            #expect(config.maxContextTokens == defaultBudget)
        }

        @Test("a profile that pins only reasoning keeps the preset's sampling values")
        func partialContextKeepsPresetValues() async throws {
            let app = plainState(workspacePath: Self.temporaryWorkspace("partial"))
            let (_, config) = await app.makeTurnAgent(
                preset: Self.preset,
                profileContext: ProfileContextConfig(reasoningEffort: "low"),
                thinking: "high",
                headless: true,
                sessionID: "s-plain"
            )

            #expect(config.reasoningEffort == "low")
            #expect(config.contextLength == 8_000)
            #expect(config.maxOutputTokens == 512)
            #expect(config.temperature == 0.2)
            #expect(config.topP == 0.5)
        }

        @Test("an unparseable preset url fails closed instead of trapping")
        func unparseableBaseURLFailsClosed() async throws {
            let app = plainState(workspacePath: Self.temporaryWorkspace("bad-url"))
            var bad = Self.preset
            bad.baseURL = ""

            let (_, config) = await app.makeTurnAgent(
                preset: bad,
                profileContext: nil,
                thinking: "medium",
                headless: false,
                sessionID: "s-plain"
            )

            #expect(config.baseURL.absoluteString == "https://invalid.invalid")
        }
    }
}

/// a memory provider the factory test can recognise by its output — proving
/// `Configuration.memoryProvider` came from `AppState.memory`, not from the
/// configuration's `FileMemoryProvider` default.
private struct StubMemoryProvider: MemoryProvider {
    let marker: String

    func readMemory() async throws -> String { marker }
    func readUser() async throws -> String { marker }
    func appendMemory(_ text: String) async throws {}
    func replaceMemory(old: String, new: String) async throws {}
    func writeMemory(_ text: String) async throws {}
    func appendUser(_ text: String) async throws {}
    func replaceUser(old: String, new: String) async throws {}
    func writeUser(_ text: String) async throws {}
}