import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

/// Regression tests for the approval persistence bug: the web UI builds a
/// fresh `ArcAgent` per turn, and each agent used to construct its own
/// `ApprovalManager` — so "Allow session" died with the turn and "Allow
/// always" was never persisted. The fix: inject the long-lived manager
/// (or seed a fresh one with the persisted allowlist) via the agent config.
@Suite("Approval persistence across turn-scoped agents")
struct ApprovalSessionPersistenceTests {

    /// Danger-level detector is regex-based; any command matching `sudo\s+`
    /// or `rm\s+-rf` is dangerous-but-not-critical here.
    private let dangerous = "sudo rm -rf /tmp/scratch-build"

    private func makeConfig(
        manager: ApprovalManager? = nil,
        alwaysAllowed: [String] = []
    ) -> ArcAgent.Configuration {
        ArcAgent.Configuration(
            model: "test-model",
            provider: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "test-key",
            registry: CompileTimeToolRegistry(),
            persistSessions: false,
            approvalMode: .manual,
            approvalManager: manager,
            alwaysAllowedCommands: alwaysAllowed
        )
    }

    @Test("injected manager: allow-session pre-approval outlives the turn's agent")
    func allowSessionOutlivesTurnAgent() async throws {
        let shared = ApprovalManager(mode: .manual)
        let first = ArcAgent(config: makeConfig(manager: shared))
        await first.setApprovalPresenter { _ in .allowSession }

        let result = await first.approvalManager.requestApproval(
            command: dangerous, description: "Run it", sessionKey: "chat-1")
        #expect(result == .approved, "presenter's allow-session must resolve to approved")

        // The next turn builds a NEW agent — but shares the manager, so the
        // pre-approval carries over and a different dangerous command no
        // longer prompts.
        let second = ArcAgent(config: makeConfig(manager: shared))
        let needs = await second.approvalManager.needsApproval(
            command: "sudo chown 777 /etc/hosts", sessionKey: "chat-1")
        #expect(needs == false, "allow-session must cover later turns of the same session")
    }

    @Test("injected manager: allow-session stays scoped to its session")
    func allowSessionStaysScoped() async throws {
        let shared = ApprovalManager(mode: .manual)
        let first = ArcAgent(config: makeConfig(manager: shared))
        await first.setApprovalPresenter { _ in .allowSession }
        _ = await first.approvalManager.requestApproval(
            command: dangerous, description: "Run it", sessionKey: "chat-1")

        let second = ArcAgent(config: makeConfig(manager: shared))
        let needs = await second.approvalManager.needsApproval(
            command: dangerous, sessionKey: "chat-2")
        #expect(needs == true, "pre-approval must not leak into other sessions")
    }

    @Test("injected manager: always-allow persists to the shared manager")
    func alwaysAllowPersistsToSharedManager() async throws {
        let shared = ApprovalManager(mode: .manual)
        let first = ArcAgent(config: makeConfig(manager: shared))
        await first.setApprovalPresenter { _ in .alwaysAllow }
        _ = await first.approvalManager.requestApproval(
            command: dangerous, description: "Run it", sessionKey: "chat-1")

        let second = ArcAgent(config: makeConfig(manager: shared))
        let needs = await second.approvalManager.needsApproval(
            command: dangerous, sessionKey: "chat-2")
        #expect(needs == false, "always-allow must survive the turn agent being torn down")
    }

    @Test("config allowlist seeds a fresh (non-injected) manager")
    func configAllowlistSeedsManager() async throws {
        let agent = ArcAgent(config: makeConfig(alwaysAllowed: [dangerous]))
        let exempt = await agent.approvalManager.needsApproval(
            command: dangerous, sessionKey: "s")
        let other = await agent.approvalManager.needsApproval(
            command: "sudo reboot", sessionKey: "s")
        #expect(exempt == false, "persisted allowlist commands must not prompt")
        #expect(other == true, "anything else still prompts")
    }
}
