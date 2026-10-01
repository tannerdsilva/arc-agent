import Foundation
import Testing
@testable import arc_agent_webui

/// Settings → Main model / Auxiliary models: choosing a Model configuration
/// for an auxiliary task must copy provider / model / base URL and the
/// config's own API key (empty key inherits the main key at resolution time).
@Suite("Model configuration → auxiliary override mapping")
struct ModelPickerTests {

    @Test("Auxiliary override mirrors provider, model, base URL and API key")
    func mapsFields() {
        let preset = ModelConfigPreset(
            name: "Qwen",
            model: "Qwen3.6-35B-A3B-OptiQ-4bit",
            provider: "custom",
            baseURL: "http://127.0.0.1:8080/v1",
            apiKey: "sk-test",
            contextLength: 32_000
        )
        let ov = preset.auxiliaryOverride
        #expect(ov.provider == "custom")
        #expect(ov.model == "Qwen3.6-35B-A3B-OptiQ-4bit")
        #expect(ov.baseURL == "http://127.0.0.1:8080/v1")
        #expect(ov.apiKey == "sk-test")
        #expect(ov.isSet)
    }

    @Test("Empty API key still routes to the config (key inherits at resolution)")
    func emptyKeyInherits() {
        let preset = ModelConfigPreset(
            name: "Main",
            model: "deepseek-v4-flash-vision-exp",
            provider: "custom",
            baseURL: "https://api.example.com/v1"
        )
        let ov = preset.auxiliaryOverride
        #expect(ov.isSet)
        #expect(ov.apiKey.isEmpty)
    }
}
