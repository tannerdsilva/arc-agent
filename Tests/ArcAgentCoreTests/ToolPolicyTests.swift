import Testing
@testable import ArcAgentCore
import Foundation

extension ArcCoreTestRoot {
    /// Tool policy, blueprints, checkpoints (arc parity).
    @Suite("Tool policies", .serialized)
    struct ToolPolicyTests {

        @Test("glob matching")
        func globs() {
            #expect(ToolPolicy.wildcardMatch(pattern: "terminal", value: "terminal"))
            #expect(ToolPolicy.wildcardMatch(pattern: "browser_*", value: "browser_console"))
            #expect(!ToolPolicy.wildcardMatch(pattern: "browser_*", value: "terminal"))
            #expect(ToolPolicy.wildcardMatch(pattern: "file*", value: "file"))
        }

        @Test("later rules win; disabled policy allows all")
        func decide() {
            let rules = [
                ToolPolicyRule(match: "terminal", action: .deny, reason: "prod safety"),
                ToolPolicyRule(match: "terminal", toolset: "file", action: .allow),
            ]
            let config = ToolPolicyConfig(enabled: true, rules: rules)
            let d = ToolPolicy.decide(toolName: "terminal", toolset: "file", config: config)
            #expect(d.action == .allow)
            let d2 = ToolPolicy.decide(toolName: "terminal", toolset: "shell", config: config)
            #expect(d2.action == .deny)
            let off = ToolPolicy.decide(toolName: "terminal", toolset: "shell", config: ToolPolicyConfig())
            #expect(off.action == .allow)
        }
    }
}

extension ArcCoreTestRoot {
    @Suite("Blueprints", .serialized)
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
}

extension ArcCoreTestRoot {
    @Suite("CheckpointStore", .serialized)
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
}

// MARK: - Tool policy action honesty (T5a)

extension ArcCoreTestRoot {
    /// `requireApproval` promised a prompt no surface could make. The case is
    /// now `denyWithHint`; these pin that the old spelling still loads, that the
    /// new one is what gets written, and that the old one cannot be written.
    @Suite("Tool policy honesty", .serialized)
    struct ToolPolicyHonestyTests {

        @Test("the legacy spelling decodes to a refusal, not a prompt")
        func legacySpellingDecodesToRefusal() throws {
            let json = """
            {"enabled": true, "rules": [{"match": "terminal", "action": "requireApproval", "reason": "shell"}]}
            """
            let config = try JSONDecoder().decode(ToolPolicyConfig.self, from: Data(json.utf8))
            #expect(config.rules.first?.action == .denyWithHint)

            let decision = ToolPolicy.decide(
                toolName: "terminal", toolset: "terminal", config: config)
            #expect(decision.action == .denyWithHint)
            #expect(decision.reason == "shell")
        }

        @Test("the honest spelling round-trips and is what gets written")
        func honestSpellingRoundTrips() throws {
            let config = ToolPolicyConfig(enabled: true, rules: [
                ToolPolicyRule(match: "terminal", action: .denyWithHint),
            ])
            let data = try JSONEncoder().encode(config)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("\"denyWithHint\""))
            #expect(!text.contains("requireApproval"))

            let back = try JSONDecoder().decode(ToolPolicyConfig.self, from: data)
            #expect(back == config)
        }

        @Test("the legacy name cannot be constructed")
        func legacyNameIsNotAWritableCase() {
            // decode-only: the old spelling is accepted on the way in and can
            // never be produced by the type again.
            #expect(ToolPolicyAction(rawValue: "requireApproval") == nil)
            #expect(ToolPolicyAction(rawValue: "denyWithHint") == .denyWithHint)
        }
    }
}
