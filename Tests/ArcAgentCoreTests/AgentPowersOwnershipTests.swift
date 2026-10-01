import Foundation
import Testing

@testable import ArcAgentCore

/// The gate is process-global; a plainly-constructed agent (the gateway's
/// shape, and the daemon's session agents) must never reset an active
/// lockdown. The daemon installs the gate once at boot from config.json.
@Suite("Agent powers ownership")
struct AgentPowersOwnershipTests {

    @Test("a default-powers agent does not clobber an active lockdown")
    func defaultAgentPreservesGate() throws {
        AgentPowers.configure(AgentPowersConfig(
            skillsManage: false,
            lockedSkills: ["secret"],
            profileEdit: false
        ))
        defer { AgentPowers.configure(AgentPowersConfig()) }

        let registry = try ArcAgentCore.buildDefaultRegistry()
        _ = ArcAgent(config: ArcAgent.Configuration(
            model: "test-model",
            provider: "test",
            baseURL: URL(string: "http://127.0.0.1:9/v1")!,
            apiKey: "",
            registry: registry,
            sessionStore: FileSessionStore(),
            memoryProvider: FileMemoryProvider(),
            skills: []
        ))

        #expect(AgentPowers.canManageSkills() == false)
        #expect(AgentPowers.skillIsLocked("secret"))
    }
}