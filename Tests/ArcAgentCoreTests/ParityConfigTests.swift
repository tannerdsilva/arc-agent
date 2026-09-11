import Testing
import Foundation
@testable import ArcAgentCore

/// Config plumbing for the Hermes-parity knobs (A/B cycle 2).
@Suite("Parity config decode")
struct ParityConfigTests {

    @Test("reasoningEffort and maxOutputTokens decode from config.json")
    func parityKnobs() throws {
        let json = """
        {
          "agent": {"reasoningEffort": "max"},
          "model": {"defaultModel": "deepseek-v4-flash-vision-exp",
                    "provider": "custom", "maxOutputTokens": 512000}
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cfg = loadConfig(from: url)
        #expect(cfg.agent.reasoningEffort == "max")
        #expect(cfg.model.maxOutputTokens == 512000)
        #expect(cfg.model.defaultModel == "deepseek-v4-flash-vision-exp")
    }
}
