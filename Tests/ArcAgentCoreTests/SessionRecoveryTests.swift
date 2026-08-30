import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - Session Agent Crash Supervision (Phase C) + Concurrency (Phase D)

@Suite("Session Recovery")
struct SessionRecoveryTests {

    private func makeRegistry(restartDelay: UInt64 = 0) -> SessionRegistry {
        let config = SessionRegistry.AgentConfig(
            model: "gpt-4o",
            provider: "openai",
            baseURL: "https://api.openai.com/v1",
            apiKey: ""
        )
        return SessionRegistry(
            agentConfig: config,
            deliveryManager: DeliveryManager(),
            profileManager: ProfileManager(),
            restartDelay: restartDelay
        )
    }

    /// Build a real but UNREGISTERED SessionAgent (never started) so the
    /// identity guard can be exercised with a wrong-owner crash report.
    private func makeForeignAgent(sessionID: String, registry: SessionRegistry) -> SessionAgent {
        let config = SessionRegistry.AgentConfig(
            model: "gpt-4o",
            provider: "openai",
            baseURL: "https://api.openai.com/v1",
            apiKey: ""
        )
        let (inputStream, _) = AsyncStream<IncomingMessage>.makeStream()
        let (_, responseContinuation) = AsyncStream<String>.makeStream()
        return SessionAgent(
            sessionID: sessionID,
            profile: "default",
            agentConfig: config,
            profileManager: ProfileManager(),
            incomingMessages: inputStream,
            deliveryManager: DeliveryManager(),
            registry: registry,
            responseContinuation: responseContinuation
        )
    }

    // MARK: - Policy

    @Test("respawn backoff doubles per attempt and caps at 8x")
    func respawnBackoff() {
        #expect(SessionRegistry.respawnDelay(for: 1, base: 1_000) == 1_000)
        #expect(SessionRegistry.respawnDelay(for: 2, base: 1_000) == 2_000)
        #expect(SessionRegistry.respawnDelay(for: 3, base: 1_000) == 4_000)
        #expect(SessionRegistry.respawnDelay(for: 4, base: 1_000) == 8_000)
        #expect(SessionRegistry.respawnDelay(for: 9, base: 1_000) == 8_000, "delay must cap so a crash loop never grows unbounded")
        #expect(SessionRegistry.maxSessionRestarts == 3)
    }

    // MARK: - Identity guard

    @Test("crash reported for a superseded agent leaves the successor untouched")
    func supersededCrashIsIgnored() async {
        let registry = makeRegistry()
        _ = await registry.getOrCreate(sessionID: "recovery-superseded")

        guard let current = await registry.agent(for: "recovery-superseded") else {
            Issue.record("expected a live agent")
            return
        }
        let foreign = makeForeignAgent(sessionID: "recovery-superseded", registry: registry)

        // A wrong-owner crash report must not disturb the current generation.
        await registry.handleAgentCrash(sessionID: "recovery-superseded", agent: foreign)

        let after = await registry.agent(for: "recovery-superseded")
        #expect(after.map(ObjectIdentifier.init) == ObjectIdentifier(current),
            "successor must survive a foreign crash report")
        #expect(await registry.crashCount(for: "recovery-superseded") == 0,
            "a foreign crash must not consume the crash budget")
    }

    // MARK: - Crash handling

    @Test("crash of the current agent removes it and records an attempt")
    func currentCrashIsHandled() async {
        // A long restart delay keeps the (unstructured) respawn sleeping so
        // this test observes the removal/counting without the restart racing.
        let registry = makeRegistry(restartDelay: 3_600_000_000_000)
        _ = await registry.getOrCreate(sessionID: "recovery-count")

        guard let current = await registry.agent(for: "recovery-count") else {
            Issue.record("expected a live agent")
            return
        }

        await registry.handleAgentCrash(sessionID: "recovery-count", agent: current)

        #expect(await registry.agent(for: "recovery-count") == nil,
            "the crashed generation must be unregistered")
        #expect(await registry.crashCount(for: "recovery-count") == 1)
        #expect(await registry.activeCount == 0)
    }

    @Test("respawn fills a vacant session with a fresh generation")
    func respawnFillsVacancy() async {
        let registry = makeRegistry(restartDelay: 0)
        let handle = await registry.getOrCreate(sessionID: "recovery-restart")

        // End the first generation the graceful way: it tears itself down,
        // releasing its LMDB environment, leaving the session vacant —
        // exactly the state a real crash produces before supervision fires.
        handle.inputContinuation.finish()
        var vacant = false
        for _ in 0..<200 {
            if await registry.agent(for: "recovery-restart") == nil {
                vacant = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(vacant, "first generation should have torn itself down")

        // Now the registry's auto-restart path (the same path the crash
        // supervisor calls) fills the vacancy.
        await registry.respawnIfVacant(sessionID: "recovery-restart", profile: "default")

        let fresh = await registry.agent(for: "recovery-restart")
        #expect(fresh != nil, "respawn should install a new generation")
        #expect(await registry.activeCount == 1)
        #expect(await registry.crashCount(for: "recovery-restart") == 0,
            "an explicit getOrCreate resets the crash budget")
    }

    // MARK: - Concurrency

    @Test("racing getOrCreate calls serialize into one coherent generation")
    func concurrentGetOrCreateSerializes() async {
        let registry = makeRegistry()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = await registry.getOrCreate(sessionID: "recovery-race")
                }
            }
            await group.waitForAll()
        }

        // The sequential-supersede discipline means exactly one live
        // generation survives the storm, with no pile-up.
        #expect(await registry.activeCount == 1)
        #expect(await registry.agent(for: "recovery-race") != nil)
        #expect(await registry.crashCount(for: "recovery-race") == 0)
    }
}
