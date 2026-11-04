import ArcToolKit
import Foundation
import Testing
@testable import ArcWebUI
import ArcAgentCore

// ===========================================================================
// MARK: - model parameters resolve per model, never from the profile
//
// The model configuration is the single home for model parameters. The
// compression ladder resolves the bound chat's preset budget first; profiles
// do not carry parameters at all (the legacy `context` block was removed).
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("per-model parameter resolution", .serialized)
    struct UnboundChatProfileContextTests {

        private func makeApp(presets: [ModelConfigPreset], sessionConfig: [String: String] = [:]) -> AppState {
            AppState(renderFixture: AppState.RenderFixture(
                settings: { var s = AppSettings()
                    s.modelConfigs = presets
                    s.sessionConfig = sessionConfig
                    return s }(),
                profiles: [Profile(name: "default", title: "Default")]
            ))
        }

        private static let preset = ModelConfigPreset(
            name: "glm", model: "glm-5.3", provider: "custom",
            baseURL: "https://api.example.com/v1", apiKey: "",
            contextLength: 599_040, maxOutputTokens: nil,
            reasoningEffort: nil, compressionBudget: 130_048, source: "ui")

        @Test("a chat bound to a model config resolves that config's budget")
        func boundPresetBudget() async {
            let app = makeApp(presets: [Self.preset], sessionConfig: ["fresh-session": "glm"])
            let budget = await app.compressionBudget(for: "fresh-session")
            #expect(budget == 130_048)
        }

        @Test("an unbound chat falls back to the env/default ladder, not a profile")
        func unboundFallsBack() async {
            let app = makeApp(presets: [Self.preset])
            // no sessionConfig binding → no preset → env default (32k), clamped
            // to half of the global context length when one is configured.
            let budget = await app.compressionBudget(for: "fresh-session")
            #expect(budget > 0)
        }

        @Test("a profile record without parameters still binds chats")
        func profileWithoutParams() async {
            let app = makeApp(presets: [Self.preset], sessionConfig: ["sid-1": "glm"])
            // resolution no longer consults profiles for parameters; the
            // preset ladder alone decides.
            let budget = await app.compressionBudget(for: "sid-1")
            #expect(budget == 130_048)
        }
    }
}
