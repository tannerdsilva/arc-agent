import Testing
@testable import ArcAgentCore
import Foundation

/// Tool gateway, blueprints, checkpoints (arc parity).
@Suite("GatewayPolicies")
struct GatewayPolicyTests {

    @Test("glob matching")
    func globs() {
        #expect(ToolGateway.wildcardMatch(pattern: "terminal", value: "terminal"))
        #expect(ToolGateway.wildcardMatch(pattern: "browser_*", value: "browser_console"))
        #expect(!ToolGateway.wildcardMatch(pattern: "browser_*", value: "terminal"))
        #expect(ToolGateway.wildcardMatch(pattern: "file*", value: "file"))
    }

    @Test("later rules win; disabled gateway allows all")
    func decide() {
        let rules = [
            ToolGatewayRule(match: "terminal", action: .deny, reason: "prod safety"),
            ToolGatewayRule(match: "terminal", toolset: "file", action: .allow),
        ]
        let config = ToolGatewayConfig(enabled: true, rules: rules)
        let d = ToolGateway.decide(toolName: "terminal", toolset: "file", config: config)
        #expect(d.action == .allow)
        let d2 = ToolGateway.decide(toolName: "terminal", toolset: "shell", config: config)
        #expect(d2.action == .deny)
        let off = ToolGateway.decide(toolName: "terminal", toolset: "shell", config: ToolGatewayConfig())
        #expect(off.action == .allow)
    }
}

@Suite("Blueprints")
struct BlueprintTests {

    static let blueprintSkill = """
    ---
    name: nightly-report
    description: Generate the nightly report
    metadata:
      reference:
        blueprint:
          schedule: "0 9 * * *"
          deliver: origin
          model: gpt-5.2
          no_agent: false
          enabled_toolsets:
            - file
            - terminal
    ---
    Body
    """

    @Test("parses a blueprint skill")
    func parses() throws {
        let spec = try BlueprintParser.parse(Self.blueprintSkill, fallbackName: "nightly-report")
        #expect(spec != nil)
        #expect(spec?.schedule == "0 9 * * *")
        #expect(spec?.model == "gpt-5.2")
    }

    @Test("missing schedule throws; non-blueprint returns nil")
    func invalid() throws {
        let noSchedule = """
        ---
        name: x
        metadata:
          reference:
            blueprint:
              prompt: hi
        ---
        """
        #expect(throws: BlueprintError.self) {
            _ = try BlueprintParser.parse(noSchedule)
        }
        let plain = "---\nname: regular\n---\nBody"
        let result = try BlueprintParser.parse(plain)
        #expect(result == nil)
    }
}

@Suite("CheckpointStore")
struct CheckpointStoreTests {

    @Test("registry lifecycle")
    func lifecycle() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-checkpoint-tests-\(UUID().uuidString).json")
        let store = try CheckpointStore(storageURL: url)
        let cp = Checkpoint(name: "before-refactor", commit: "abc1234", createdAt: Date(),
                            message: "pre change", projectPath: "/work/proj")
        await store.add(cp, projectPath: "/work/proj")
        try await store.save()
        let loaded = try CheckpointStore(storageURL: url)
        #expect(await loaded.list(projectPath: "/work/proj").count == 1)
        #expect(await loaded.find(name: "before-refactor", projectPath: "/work/proj")?.commit == "abc1234")
        _ = await loaded.remove(name: "before-refactor", projectPath: "/work/proj")
        try await loaded.save()
        let final = try CheckpointStore(storageURL: url)
        #expect(await final.list(projectPath: "/work/proj").isEmpty)
    }
}
