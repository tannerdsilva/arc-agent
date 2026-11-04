import Testing
import Foundation
@testable import ArcAgentCore

/// Per-model parameters: the model configuration (not the profile) is the
/// single home for model parameters.
@Suite("ModelParameterStore")
struct ModelParameterStoreTests {

    private func tempStore(_ presets: [[String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-mps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        let body: [String: Any] = ["modelConfigs": presets]
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        return url
    }

    @Test("parameters resolve by model name")
    func resolveByModel() throws {
        let url = try tempStore([[
            "name": "managed",
            "model": "glm-5.3",
            "contextLength": 20480,
            "maxOutputTokens": 4096,
            "temperature": 0.7,
            "topP": 0.9,
            "reasoningEffort": "medium",
            "compressionBudget": 8000,
        ]])
        let p = try #require(ModelParameterStore.parameters(forModel: "glm-5.3", settingsURL: url))
        #expect(p.contextLength == 20480)
        #expect(p.maxOutputTokens == 4096)
        #expect(p.temperature == 0.7)
        #expect(p.topP == 0.9)
        #expect(p.reasoningEffort == "medium")
        #expect(p.compressionBudget == 8000)
    }

    @Test("unknown model yields nil (fall back to global config)")
    func unknownModelNil() throws {
        let url = try tempStore([["name": "x", "model": "glm-5.3"]])
        #expect(ModelParameterStore.parameters(forModel: "other", settingsURL: url) == nil)
    }

    @Test("missing store yields nil, not a crash")
    func missingStoreNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-mps-missing-\(UUID().uuidString)/settings.json")
        #expect(ModelParameterStore.parameters(forModel: "m", settingsURL: url) == nil)
    }

    @Test("undecodable store yields nil (tolerant decode)")
    func undecodableNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-mps-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        try Data("not json".utf8).write(to: url)
        #expect(ModelParameterStore.parameters(forModel: "m", settingsURL: url) == nil)
    }

    @Test("preset without the field decodes as nil (older stores)")
    func olderStoreTolerated() throws {
        let url = try tempStore([["name": "x", "model": "m"]])
        let p = try #require(ModelParameterStore.parameters(forModel: "m", settingsURL: url))
        #expect(p.contextLength == nil)
        #expect(p.compressionBudget == nil)
        #expect(p.reasoningEffort == nil)
    }
}
