import Foundation
import Testing
import AsyncHTTPClient
import ArcToolKit
@testable import ArcAgentCore

// MARK: - Fresh-context cron sessions
//
// A recurring job's earlier runs must not leak into later runs' contexts.
// The transcript still persists (the job's chat shows every run) — the gate
// is purely on ``ArcAgent/restoreSessionIfNeeded``.

extension ArcCoreTestRoot {
    @Suite("Cron Fresh Context", .serialized)
    struct CronFreshContextTests {

        private func tempStore() -> FileSessionStore {
            FileSessionStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-freshctx-\(UUID().uuidString)", isDirectory: true))
        }

        private func makeAgent(sessionID: String, store: FileSessionStore,
                               restore: Bool) async -> ArcAgent {
            let config = ArcAgent.Configuration(
                model: "test-model",
                provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "test",
                registry: CompileTimeToolRegistry(),
                sessionStore: store,
                maxIterations: 5,
                maxTurnDuration: 30,
                persistSessions: true,
                restoreHistoryOnStart: restore,
                approvalMode: .off,
                sessionID: sessionID
            )
            return ArcAgent(config: config)
        }

        @Test("stored history enters the context when restore is on")
        func restoreOn() async throws {
            let store = tempStore()
            let sid = "cron-restore-on"
            let previous = Message(role: .assistant, content: "earlier run output")
            try await store.create(Session(
                id: sid, createdAt: Date(), updatedAt: Date(),
                model: "test-model", provider: "openai",
                title: nil, messages: [previous],
                source: "cli", workspaceKey: WorkspacePath.root))

            let agent = await makeAgent(sessionID: sid, store: store, restore: true)
            await agent.restoreSessionIfNeeded()
            #expect(await agent.contextMessageCount == 1, "restored mode loads the stored transcript")
        }

        @Test("fresh-context mode leaves stored history out of the context but appends to the store")
        func restoreOff() async throws {
            let store = tempStore()
            let sid = "cron-restore-off"
            try await store.create(Session(
                id: sid, createdAt: Date(), updatedAt: Date(),
                model: "test-model", provider: "openai",
                title: nil, messages: [Message(role: .assistant, content: "run one output")],
                source: "cli", workspaceKey: WorkspacePath.root))

            let agent = await makeAgent(sessionID: sid, store: store, restore: false)
            await agent.restoreSessionIfNeeded()
            #expect(await agent.contextMessageCount == 0, "fresh-context mode must not load prior runs")

            // The next turn still appends to the EXISTING store session
            // (no duplicate-create): the internal watermark must know the
            // session already exists.
            #expect(await agent.storeSessionKnown, "existence probe marks the session as existing")
        }

        @Test("fresh-context mode with no stored session starts clean and creates on persist")
        func restoreOffNoSession() async throws {
            let store = tempStore()
            let agent = await makeAgent(sessionID: "cron-brand-new", store: store, restore: false)
            await agent.restoreSessionIfNeeded()
            #expect(await agent.contextMessageCount == 0)
            #expect(!(await agent.storeSessionKnown), "no stored session yet — first persist creates it")
        }
    }
}
