import Testing
import Foundation
import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {

    /// MoA enablement is policy (settings backbone, slice 2).
    ///
    /// `moa.enabled` in `~/.arc/config.json` is the one switch: the UI turn
    /// agent and a daemon session read the same block, so the two surfaces
    /// cannot disagree any more. The reference-model guard is load-bearing —
    /// MoA with no reference models does nothing, so the block stays off.
    @Suite("moa policy", .serialized)
    struct MoAPolicyTests {

        private static let preset = ModelConfigPreset(
            name: "moa-stub",
            model: "stub-model-1",
            provider: "custom",
            baseURL: "http://127.0.0.1:9/v1"
        )

        private static func temporaryWorkspace(_ label: String) -> String {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-moa-\(label)-\(UUID().uuidString)", isDirectory: true)
                .path
        }

        /// A state whose only configuration is `arc` (a render fixture owns no
        /// store, so its in-memory config is the whole story).
        private func state(_ arc: ArcConfig) -> AppState {
            var f = AppState.RenderFixture()
            f.settings.workspaces = [WorkspaceEntry(
                name: "main", path: Self.temporaryWorkspace("main"))]
            f.settings.activeWorkspace = "main"
            f.arcConfig = arc
            return AppState(renderFixture: f)
        }

        private func turnMoA(_ app: AppState) async -> MoAConfig {
            let (_, config) = await app.makeTurnAgent(
                preset: Self.preset,
                thinking: "medium",
                headless: true,
                sessionID: "s-moa"
            )
            return config.moa
        }

        // MARK: - the decode

        @Test("a config that enables MoA turns the turn agent's MoA on")
        func enabledConfigTurnsTheAgentOn() async throws {
            let json = """
            {"moa": {"enabled": true, "reference_models": [{"model": "m"}]}}
            """
            let arc = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
            #expect(arc.moa.enabled)
            #expect(arc.moa.referenceModels.count == 1)

            #expect(AppState.turnMoAConfig(arc.moa).enabled,
                    "the policy's on-switch reaches the agent unchanged")
            #expect(await turnMoA(state(arc)).enabled,
                    "the UI turn agent runs with the policy's MoA")
        }

        @Test("no reference models means nothing to fan out")
        func emptyReferenceModelsForcesOff() async throws {
            let json = """
            {"moa": {"enabled": true, "reference_models": []}}
            """
            let arc = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
            #expect(arc.moa.enabled, "the file says enabled")

            #expect(AppState.turnMoAConfig(arc.moa).enabled == false,
                    "an enabled block with no reference models must stay off")
            #expect(await turnMoA(state(arc)).enabled == false)
        }

        @Test("the camelCase referenceModels spelling is not a config key")
        func camelCaseReferenceModelsDecodesEmpty() throws {
            // The plan's gate spells the key `referenceModels`. The decoder is
            // snake_case (`reference_models`, reference parity), so that
            // spelling decodes to an EMPTY reference list — and the guard then
            // forces MoA off. Pinned so a future "fix" cannot quietly add a
            // second accepted spelling without deciding to.
            let json = """
            {"moa": {"enabled": true, "referenceModels": [{"model": "m"}]}}
            """
            let arc = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
            #expect(arc.moa.referenceModels.isEmpty)
            #expect(AppState.turnMoAConfig(arc.moa).enabled == false)
        }

        // MARK: - the two surfaces

        @Test("one ArcConfig: the UI turn agent and the daemon's session config agree")
        func bothSurfacesAgree() async throws {
            var arc = ArcConfig()
            arc.moa.enabled = true
            arc.moa.referenceModels = [MoAConfig.Role(model: "m")]

            let turn = await turnMoA(state(arc))
            // exactly what ArcDaemon builds for its SessionRegistry.
            let daemon = SessionRegistry.AgentConfig(
                model: "m", provider: "p", baseURL: "http://127.0.0.1:9/v1",
                apiKey: "", moa: arc.moa
            )

            #expect(turn.enabled, "the UI turn agent must honour moa.enabled")
            #expect(daemon.moa.enabled, "the daemon session must honour moa.enabled")
            #expect(turn.enabled == daemon.moa.enabled,
                    "the two surfaces must not disagree about one config")
        }

        @Test("a disabled config is off on both surfaces")
        func bothSurfacesAgreeOff() async throws {
            var arc = ArcConfig()
            arc.moa.referenceModels = [MoAConfig.Role(model: "m")]
            #expect(arc.moa.enabled == false)

            let turn = await turnMoA(state(arc))
            let daemon = SessionRegistry.AgentConfig(
                model: "m", provider: "p", baseURL: "http://127.0.0.1:9/v1",
                apiKey: "", moa: arc.moa
            )
            #expect(turn.enabled == false)
            #expect(daemon.moa.enabled == false)
        }

        // MARK: - the switch

        /// The `<input …>` tag carrying `id="<id>"`.
        private func switchTag(_ html: String, id: String) -> Substring? {
            guard let idRange = html.range(of: "id=\"\(id)\"") else { return nil }
            let head = html[html.startIndex..<idRange.lowerBound]
            let start = head.range(of: "<input", options: .backwards)?.lowerBound
                ?? idRange.lowerBound
            let end = html.range(of: ">", range: idRange.upperBound..<html.endIndex)?.upperBound
                ?? idRange.upperBound
            return html[start..<end]
        }

        @Test("the MoA switch renders the policy")
        func switchRendersThePolicy() async {
            for enabled in [true, false] {
                var fixture = AppState.RenderFixture()
                fixture.settings.theme = "light"
                fixture.arcConfig.moa.enabled = enabled
                let html = await AppState(renderFixture: fixture).settingsMain().markup.html
                let tag = switchTag(html, id: "set-moa")
                #expect(tag != nil, "the storage section must render the MoA switch")
                #expect(tag?.contains("checked") == enabled,
                        "moa.enabled = \(enabled) must render the switch \(enabled ? "on" : "off")")
            }
        }

        @Test("the switch does not read a stored toggle")
        func switchDoesNotReadSettings() throws {
            let views = try String(contentsOfFile: "Sources/ArcWebUI/Views.swift",
                                   encoding: .utf8)
            #expect(!views.contains("settings.moaEnabled"),
                    "the switch must read moa.enabled, not a settings.json toggle")
        }
    }
}
