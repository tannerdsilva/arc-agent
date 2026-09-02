import Foundation
import Testing
@testable import ArcAgentCore

@Suite("Auxiliary models")
struct AuxiliaryModelsTests {

    @Test("all 11 Hermes tasks exist with stable keys and labels")
    func allTasks() {
        let expected = [
            "vision", "web_extract", "compression", "approval", "mcp",
            "title_gen", "skills_hub", "curator", "kanban_decomposer",
            "profile_describer", "triage",
        ]
        #expect(AuxiliaryTask.allCases.count == 11)
        #expect(AuxiliaryTask.allCases.map(\.key) == expected)
        for task in AuxiliaryTask.allCases {
            #expect(!task.displayName.isEmpty)
            #expect(!task.detail.isEmpty)
        }
    }

    @Test("resolved() merges an override over the main model, inheriting gaps")
    func resolution() {
        let main = ModelConfig(defaultModel: "gpt-4o", provider: "openai", baseURL: "https://api.openai.com/v1")
        var set = AuxiliaryModelSet()
        set.byTask[.vision] = AuxiliaryOverride(model: "qwen-vl", baseURL: "http://127.0.0.1:8000/v1")

        let routed = set.resolved(for: .vision, over: main)
        #expect(routed.model == "qwen-vl")
        #expect(routed.provider == "openai")            // inherited
        #expect(routed.baseURL == "http://127.0.0.1:8000/v1")

        let unassigned = set.resolved(for: .titleGeneration, over: main)
        #expect(unassigned.model == "gpt-4o")           // fully inherited
        #expect(unassigned.baseURL == "https://api.openai.com/v1")
    }

    @Test("decodes a Hermes-shaped auxiliary block tolerantly and round-trips")
    func tolerantDecode() throws {
        let json = """
        {"vision":{"model":"qwen-vl","baseURL":"http://x/v1"},
         "web_extract":{"provider":"custom"},
         "unknown_task":{"model":"z"}}
        """
        let set = try JSONDecoder().decode(AuxiliaryModelSet.self, from: Data(json.utf8))
        #expect(set.byTask[.vision]?.model == "qwen-vl")
        #expect(set.byTask[.vision]?.provider == "")                 // absent → inherit
        #expect(set.byTask[.webExtract]?.provider == "custom")
        #expect(set.byTask.count == 2)                               // unknown key ignored

        let encoded = try JSONEncoder().encode(set)
        let back = try JSONDecoder().decode(AuxiliaryModelSet.self, from: encoded)
        #expect(back == set)
    }

    @Test("ArcConfig carries an auxiliary block with tolerant decode")
    func arcConfigIntegration() throws {
        let json = #"{"model":{"defaultModel":"x"},"auxiliary":{"title_gen":{"model":"tiny"}}}"#
        let cfg = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
        #expect(cfg.auxiliary.override(for: .titleGeneration)?.model == "tiny")
        #expect(cfg.auxiliary.override(for: .vision) == nil)
        #expect(cfg.auxiliary.resolved(for: .triage, over: cfg.model).model == "x")
    }
}
