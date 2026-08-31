import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - Partial Config Decode Tests
//
// Regression: `~/.arc/config.json` in the wild contains only some sections
// (e.g. just `model`, `agent`, `security`). Swift's *synthesized* `Codable`
// requires every key to be present, so decoding threw, and `loadConfig`
// **silently discarded the entire file**, falling back to compiled-in
// defaults (provider "openai", baseURL nil, empty API key).
//
// Result: the gateway talked to `https://api.openai.com/v1` with no key,
// got a 401 on every turn, and the real configured endpoint was ignored.
//
// The fix: decode each section (and each field within a section) with a
// per-field default, so a partial config merges over defaults instead of
// nuking them. Missing keys must never discard values that are present.
// =========================================================================

private func tempConfigURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("arc-partial-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.json")
}

@Test("partial config with only model+agent+security decodes and keeps present values")
func partialConfigKeepsPresentSections() throws {
    let url = try tempConfigURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let json = """
    {
      "model": {
        "defaultModel": "unsloth/Qwen3.8-27B-NVFP4",
        "provider": "sglang",
        "baseURL": "http://172.28.174.42:8001/v1"
      },
      "agent": {
        "maxIterations": 25,
        "persistSessions": true,
        "loadSkills": false
      },
      "security": {
        "approvalMode": "manual"
      }
    }
    """
    try json.data(using: .utf8)!.write(to: url)

    let config = loadConfig(from: url)

    // Present values must survive (this is what was silently lost before).
    #expect(config.model.defaultModel == "unsloth/Qwen3.8-27B-NVFP4")
    #expect(config.model.provider == "sglang")
    #expect(config.model.baseURL == "http://172.28.174.42:8001/v1")
    #expect(config.agent.maxIterations == 25)
    #expect(config.agent.persistSessions == true)
    #expect(config.agent.loadSkills == false)

    // Missing sections must fall back to compiled-in defaults.
    #expect(config.terminal.defaultTimeout == 180)
    #expect(config.terminal.allowBackground == true)
    #expect(config.delegation.maxConcurrentChildren == 12)
    #expect(config.delegation.maxSpawnDepth == 3)
    #expect(config.memory.enabled == true)
    #expect(config.security.yoloMode == false)
}

@Test("partial section within config decodes with per-field defaults")
func partialSectionUsesPerFieldDefaults() throws {
    let url = try tempConfigURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    // `agent` section present but missing `loadSkills`; `model` missing `baseURL`.
    let json = """
    {
      "model": {
        "defaultModel": "custom-model",
        "provider": "sglang"
      },
      "agent": {
        "maxIterations": 7,
        "persistSessions": false
      }
    }
    """
    try json.data(using: .utf8)!.write(to: url)

    let config = loadConfig(from: url)

    #expect(config.model.defaultModel == "custom-model")
    #expect(config.model.provider == "sglang")
    #expect(config.model.baseURL == nil)   // absent -> default nil
    #expect(config.agent.maxIterations == 7)
    #expect(config.agent.persistSessions == false)
    #expect(config.agent.loadSkills == true)  // absent -> default true
}

@Test("full config still round-trips with all sections present")
func fullConfigRoundTrip() throws {
    let url = try tempConfigURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let original = ArcConfig(
        model: ModelConfig(defaultModel: "gpt-5", provider: "anthropic", baseURL: "https://x.example/v1"),
        agent: AgentConfig(maxIterations: 50, persistSessions: false, loadSkills: true),
        security: SecurityConfig(approvalMode: "off", yoloMode: true)
    )
    try saveConfig(original, to: url)

    let loaded = loadConfig(from: url)
    #expect(loaded == original)
}
