import Testing
@testable import ArcAgentCore
import Foundation

/// Session heartbeats (Hermes `features/heartbeat.md`).
@Suite("Heartbeat", .serialized)
struct HeartbeatTests {

    private var chat: ChatTarget {
        ChatTarget(platform: "telegram", chatID: "42", threadID: nil)
    }

    private func tempStore() throws -> HeartbeatStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-hb-tests-\(UUID().uuidString).json")
        let store = try HeartbeatStore()
        HeartbeatStore.setStorageURL(url)
        return store
    }

    @Test("interval parser accepts Hermes forms and rejects sub-minute")
    func intervalParsing() {
        #expect(HeartbeatInterval.parse("90s") == 90)
        #expect(HeartbeatInterval.parse("10m") == 600)
        #expect(HeartbeatInterval.parse("2h") == 7200)
        #expect(HeartbeatInterval.parse("1d") == 86400)
        #expect(HeartbeatInterval.parse("45s") == nil)
        #expect(HeartbeatInterval.parse("bogus") == nil)
        #expect(HeartbeatInterval.parse("0m") == nil)
        #expect(HeartbeatInterval.format(86400) == "1d")
        #expect(HeartbeatInterval.format(600) == "10m")
        #expect(HeartbeatInterval.format(90) == "90s")
    }

    @Test("set/status/pause/resume/clear lifecycle")
    func lifecycle() async throws {
        let store = try tempStore()
        await store.set(sessionID: "s1", intervalSeconds: 600, prompt: "Check CI", chat: chat)
        let hb = await store.status(sessionID: "s1")
        #expect(hb?.intervalSeconds == 600)
        #expect(hb?.prompt == "Check CI")
        #expect(hb?.paused == false)

        await store.pause(sessionID: "s1")
        #expect(await store.status(sessionID: "s1")?.paused == true)
        // Paused: never due even with an ancient nextFireAt.
        await store.resume(sessionID: "s1")
        #expect(await store.status(sessionID: "s1")?.paused == false)

        await store.clear(sessionID: "s1")
        #expect(await store.status(sessionID: "s1") == nil)
    }

    @Test("due heartbeat fires once and re-anchors (coalescing)")
    func coalesce() async throws {
        let store = try tempStore()
        await store.set(sessionID: "s1", intervalSeconds: 600, prompt: "Watch", chat: chat,
                        nextFireAt: Date().addingTimeInterval(-3600))
        let first = await store.consumeIfDue(sessionID: "s1", now: Date())
        #expect(first?.prompt == "Watch")
        // Immediately after, not due again (re-anchored to now+600).
        let second = await store.consumeIfDue(sessionID: "s1", now: Date())
        #expect(second == nil)
    }

    @Test("adoptChat fills an unset target once")
    func adopt() async throws {
        let store = try tempStore()
        await store.set(sessionID: "s1", intervalSeconds: 600, prompt: "Watch",
                        chat: ChatTarget(platform: "", chatID: "", threadID: nil))
        await store.adoptChat(sessionID: "s1", chat: chat)
        #expect(await store.status(sessionID: "s1")?.chat.platform == "telegram")
        // Already set: no override.
        await store.adoptChat(sessionID: "s1", chat: ChatTarget(platform: "discord", chatID: "9", threadID: nil))
        #expect(await store.status(sessionID: "s1")?.chat.platform == "telegram")
    }

    @Test("synthetic heartbeat message enters the merged stream between turns")
    func injector() async throws {
        let store = try tempStore()
        await store.set(sessionID: "s1", intervalSeconds: 60, prompt: "Deploy check", chat: chat,
                        nextFireAt: Date().addingTimeInterval(-1))
        let (stream, continuation) = AsyncStream<IncomingMessage>.makeStream()
        let merged = HeartbeatInjector.merged(
            over: stream, sessionID: "s1", store: store, pollInterval: .milliseconds(80)
        )
        // Drive consumption.
        let collected = Task {
            var texts: [String] = []
            for await m in merged { texts.append(m.text) }
            return texts
        }
        continuation.yield(IncomingMessage(
            id: "u1", chat: chat, text: "hello", senderID: "u",
            senderName: nil, isReply: false, replyToID: nil, isMention: false, raw: nil
        ))
        try await Task.sleep(for: .milliseconds(400))
        continuation.finish()
        let texts = await collected.value
        #expect(texts.contains("hello"))
        #expect(texts.contains("Deploy check"))
    }
}
