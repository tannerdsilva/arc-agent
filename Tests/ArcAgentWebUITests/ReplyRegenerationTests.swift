import Foundation
import Synchronization
import Testing
import WebUICore

@testable import ArcAgentCore
@testable import ArcWebUI

// ===========================================================================
// MARK: - reply regeneration
//
// "Regenerate" re-asks the prompt behind one assistant reply as a new turn.
// The transcript is append-only on the Tessera backend, so the old exchange is
// never rewritten; these tests pin the prompt lookup, the appended attempt,
// and the two pieces of composer state a regenerate must not consume.
// ===========================================================================

/// the scripted provider a regenerated turn runs against.
final class RegenScriptClient: LLMClient, Sendable {

    private let requests = Mutex<[[Message]]>([])

    /// the messages of every request the turn sent, in order.
    var captured: [[Message]] { requests.withLock { $0 } }

    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse {
        throw LLMError.apiError(statusCode: 500, message: "scripted client is streaming-only")
    }

    func complete(
        messages: [Message], tools: [[String: Any]]?, reasoningEffort: String?
    ) async throws -> LLMResponse {
        try await complete(messages: messages, tools: tools)
    }

    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error> {
        stream(messages: messages, tools: tools, reasoningEffort: nil)
    }

    func stream(
        messages: [Message], tools: [[String: Any]]?, reasoningEffort: String?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        requests.withLock { $0.append(messages) }
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMDelta(content: "regenerated answer"))
            continuation.yield(LLMDelta(content: nil, finishReason: "stop"))
            continuation.finish()
        }
    }
}

extension ArcWebUITestRoot {

    @Suite("reply prompt", .serialized)
    struct ReplyPromptTests {

        private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        private static func thread() -> [Message] {
            [
                Message(role: .user, content: "what is 2+2?", createdAt: t0,
                        displayText: "/math what is 2+2?"),
                Message(role: .assistant, content: "four", createdAt: t0.addingTimeInterval(1)),
                Message(role: .user, content: "and 3+3?", createdAt: t0.addingTimeInterval(2)),
                Message(role: .assistant, content: "six", createdAt: t0.addingTimeInterval(3)),
            ]
        }

        @Test("the nearest user message before the reply is the prompt")
        func nearestPrompt() throws {
            let prompt = try #require(ReplyPrompt(messages: Self.thread(), assistantIndex: 3))
            #expect(prompt.userMessageIndex == 2)
            #expect(prompt.content == "and 3+3?")
            #expect(prompt.displayText == nil)
        }

        @Test("the original display text rides along")
        func displayTextRidesAlong() throws {
            let prompt = try #require(ReplyPrompt(messages: Self.thread(), assistantIndex: 1))
            #expect(prompt.userMessageIndex == 0)
            #expect(prompt.content == "what is 2+2?")
            #expect(prompt.displayText == "/math what is 2+2?")
        }

        @Test("a tool-call row is not a reply")
        func toolCallRowRefused() {
            let messages = [
                Message(role: .user, content: "run it", createdAt: Self.t0),
                Message(role: .assistant, content: nil,
                        toolCalls: [ToolCall(id: "c1",
                                             function: ToolCallFunction(name: "terminal",
                                                                        arguments: "{}"))],
                        createdAt: Self.t0),
            ]
            #expect(ReplyPrompt(messages: messages, assistantIndex: 1) == nil)
        }

        @Test("a reply with no prior user message has no prompt")
        func noPriorUserRefused() {
            let messages = [Message(role: .assistant, content: "orphan", createdAt: Self.t0)]
            #expect(ReplyPrompt(messages: messages, assistantIndex: 0) == nil)
        }

        @Test("an empty prompt is not re-askable")
        func emptyPromptRefused() {
            let messages = [
                Message(role: .user, content: "   ", createdAt: Self.t0),
                Message(role: .assistant, content: "answer", createdAt: Self.t0),
            ]
            #expect(ReplyPrompt(messages: messages, assistantIndex: 1) == nil)
        }

        @Test("an out-of-range index is refused")
        func outOfRangeRefused() {
            #expect(ReplyPrompt(messages: Self.thread(), assistantIndex: 4) == nil)
            #expect(ReplyPrompt(messages: Self.thread(), assistantIndex: -1) == nil)
        }
    }

    @Suite("reply regeneration", .serialized)
    struct ReplyRegenerationTests {

        private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        private static func source() -> Session {
            Session(
                id: "sess-regen",
                createdAt: t0,
                updatedAt: t0,
                model: "regen-model",
                provider: "custom",
                messages: [
                    Message(role: .user, content: "what is 2+2?", createdAt: t0),
                    Message(role: .assistant, content: "four", createdAt: t0.addingTimeInterval(1)),
                    Message(role: .user, content: "and 3+3?", createdAt: t0.addingTimeInterval(2)),
                    Message(role: .assistant, content: "six", createdAt: t0.addingTimeInterval(3)),
                ]
            )
        }

        /// an app with a scratch store, a scripted model, and the source
        /// session already persisted (the turn's end reloads from the store).
        private static func harness() async throws -> (app: AppState, store: FileSessionStore, root: URL) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-regen-\(UUID().uuidString)", isDirectory: true)
            let store = FileSessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
            let source = source()
            try await store.create(source)

            let preset = ModelConfigPreset(
                name: "regen", model: "regen-model", provider: "custom",
                baseURL: "http://127.0.0.1:9/v1", contextLength: 8_000, maxOutputTokens: 512)
            var fixture = AppState.RenderFixture()
            fixture.settings.modelConfigs = [preset]
            fixture.settings.activeConfig = preset.name
            fixture.settings.composerDrafts[source.id] = "a draft I am typing"
            fixture.sessions = [source]
            fixture.activeSessionID = source.id
            fixture.arcConfig.tools.disabledToolsets = []
            fixture.registryTools = [StubTool(name: "skill_view", toolset: "skills")]

            let app = AppState(renderFixture: fixture)
            await app.bindRegenHarness(store: store, client: RegenScriptClient())
            await app.setAttachmentsForTest(["/tmp/keep-me.png"])
            return (app, store, root)
        }

        @Test("regenerating appends a new attempt for the same prompt")
        func appendsNewAttempt() async throws {
            let (app, store, root) = try await Self.harness()
            defer { try? FileManager.default.removeItem(at: root) }
            let sid = Self.source().id

            let prompt = try #require(await app.regenerationPrompt(sessionID: sid, assistantIndex: 1))
            #expect(prompt.userMessageIndex == 0)
            #expect(prompt.content == "what is 2+2?")

            await app.startRegeneration(sessionID: sid, prompt: prompt, pusher: { _ in })

            let stored = try #require(try await store.get(id: sid))
            #expect(stored.messages.count == 6, "the old exchange is kept; the attempt is appended")
            #expect(stored.messages[4].role == .user)
            #expect(stored.messages[4].content == "what is 2+2?")
            #expect(stored.messages[5].role == .assistant)
            #expect(stored.messages[5].content == "regenerated answer")
        }

        @Test("a regenerate click runs the re-asked turn through the wire")
        func wireDispatchRunsTurn() async throws {
            let (app, store, root) = try await Self.harness()
            defer { try? FileManager.default.removeItem(at: root) }
            let sid = Self.source().id

            let router = EventRouter()
            let controller = Controller(app: app, push: { _ in })
            await controller.wireAll(router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("msg-actions"),
                event: "click",
                data: ["targetId": .string("regen-\(enc(sid)).1")]
            ))
            #expect(outcome.fragments.isEmpty, "the turn streams through the door, not the reply")

            // the handler spawns the turn (a send must not wait for the stream);
            // the scripted provider finishes on its first delta, so a short
            // bounded wait is enough to observe the appended attempt.
            var stored = try await store.get(id: sid)
            var attempts = 0
            while (stored?.messages.count ?? 0) < 6 && attempts < 400 {
                try await Task.sleep(for: .milliseconds(5))
                stored = try await store.get(id: sid)
                attempts += 1
            }
            #expect(stored?.messages.count == 6, "the click must append a re-asked turn")
            #expect(stored?.messages.last?.content == "regenerated answer")
            #expect(stored?.messages[4].content == "what is 2+2?")
        }

        @Test("the draft and staged attachments survive a regenerate")
        func composerStateSurvives() async throws {
            let (app, _, root) = try await Self.harness()
            defer { try? FileManager.default.removeItem(at: root) }
            let sid = Self.source().id

            let prompt = try #require(await app.regenerationPrompt(sessionID: sid, assistantIndex: 3))
            await app.startRegeneration(sessionID: sid, prompt: prompt, pusher: { _ in })

            let drafts = await app.settings.composerDrafts
            let attachments = await app.attachments
            let messages = await app.sessions.first(where: { $0.id == sid })?.messages ?? []
            #expect(drafts[sid] == "a draft I am typing",
                    "a regenerate asks an old prompt; it must not consume what the reader is typing")
            #expect(attachments == ["/tmp/keep-me.png"],
                    "staged attachments belong to the reader's next message")
            #expect(messages.last?.content?.contains("[attachment:") != true,
                    "a regenerate must not attach the composer's pending files")
        }

        @Test("a chat that is already streaming refuses a regenerate at the wire")
        func streamingRefusalDoesNotAppend() async throws {
            let (app, store, root) = try await Self.harness()
            defer { try? FileManager.default.removeItem(at: root) }
            let sid = Self.source().id
            await app.beginTurnForTest(sessionID: sid)

            let router = EventRouter()
            let controller = Controller(app: app, push: { _ in })
            await controller.wireAll(router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("msg-actions"),
                event: "click",
                data: ["targetId": .string("regen-\(enc(sid)).1")]
            ))
            #expect(outcome.fragments.isEmpty)

            let stored = try #require(try await store.get(id: sid))
            #expect(stored.messages.count == 4, "a refused regenerate must not append a turn")
            let toasts = await app.toasts
            #expect(toasts.last?.text.contains("Stop the current response") == true,
                    "the refusal must explain itself: \(toasts.map(\.text))")
        }
    }
}

private extension AppState {
    /// bind the durable store and scripted provider the production init fills
    /// from the runtime.
    func bindRegenHarness(store: any SessionStore, client: any LLMClient) {
        self.store = store
        self.turnClientOverride = client
    }

    /// the composer's staged attachment paths (production fills them from the
    /// attach chips; a fixture has no chips).
    func setAttachmentsForTest(_ paths: [String]) {
        self.attachments = paths
    }

    /// make the session look mid-stream to the wire's turn guard.
    func beginTurnForTest(sessionID: String) {
        self.activeTurns[sessionID] = LiveTurn(
            sessionID: sessionID, userText: "", attachments: [])
    }
}
