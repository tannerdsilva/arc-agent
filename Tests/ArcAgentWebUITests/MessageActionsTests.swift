import Foundation
import Testing
import WebUICore

@testable import ArcAgentCore
@testable import ArcWebUI

// ===========================================================================
// MARK: - user-message actions
//
// The footer under a user message offers exactly two actions: copy (client
// delegate) and fork-here (server action). These pin the rendered shape the
// engine and the overlay actually consume — the button ids, the copy payload,
// and the event boundary — plus the fork wire id's round trip.
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("user message actions", .serialized)
    struct UserMessageActionTests {

        private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        @Test("a user message renders copy and fork-here with its cut point")
        func rendersBothActions() async throws {
            let app = AppState(renderFixture: .init())
            let message = Message(
                role: .user,
                content: "hello **there**",
                createdAt: Self.t0,
                displayText: "/skill hello"
            )
            let html = await app.messageHTML(message, rawIdx: 3, sessionID: "sess-a").markup.html

            // copy carries what the reader typed (displayText), not the
            // model-facing slash-command scaffolding in content.
            #expect(html.contains(#"data-copy="/skill hello""#),
                    "copy must take the visible text: \(html)")
            #expect(html.contains("data-copy-label"),
                    "the copy button must mark its label for the overlay's 'Copied' swap")

            let forkID = "fork-\(enc("sess-a")).3"
            #expect(html.contains("id=\"\(forkID)\""),
                    "the fork control must carry its session and cut point: \(html)")
            #expect(html.contains("data-component-id=\"msg-actions\""),
                    "one boundary must enclose the row so the engine reports the button id")
            #expect(html.contains("Fork here"))
            #expect(html.contains("Copy</span>"))
        }

        @Test("copy falls back to content when no display text exists")
        func copyUsesContentWithoutDisplayText() async {
            let app = AppState(renderFixture: .init())
            let message = Message(role: .user, content: "plain words", createdAt: Self.t0)
            let html = await app.messageHTML(message, rawIdx: 0, sessionID: "sess-a").markup.html
            #expect(html.contains(#"data-copy="plain words""#))
        }

        @Test("a transcript without a session is copy-only and carries no wire boundary")
        func copyOnlyWithoutSession() async {
            let app = AppState(renderFixture: .init())
            let message = Message(role: .user, content: "job prompt", createdAt: Self.t0)
            let html = await app.messageHTML(message, rawIdx: 2).markup.html

            #expect(html.contains(#"data-copy="job prompt""#))
            #expect(!html.contains("fork-"), "a task thread must not offer a fork it cannot open")
            #expect(!html.contains("data-component-id=\"msg-actions\""),
                    "no server action means no event boundary")
        }

        @Test("a message with no stable index offers no fork")
        func noForkWithoutIndex() async {
            let app = AppState(renderFixture: .init())
            let message = Message(role: .user, content: "orphan", createdAt: Self.t0)
            let html = await app.messageHTML(message, rawIdx: -1, sessionID: "sess-a").markup.html
            #expect(!html.contains("fork-"))
        }

        @Test("assistant replies do not grow user actions")
        func assistantRepliesUnaffected() async {
            let app = AppState(renderFixture: .init())
            let message = Message(role: .assistant, content: "reply", createdAt: Self.t0)
            let html = await app.messageHTML(message, rawIdx: 1, sessionID: "sess-a").markup.html
            #expect(!html.contains("Fork here"))
            #expect(!html.contains("data-component-id=\"msg-actions\""))
        }

        @Test("the fork wire id round-trips session and index")
        func forkTargetRoundTrip() throws {
            let session = "sess/with.dots-and_underscores"
            let id = "fork-\(enc(session)).7"
            let target = try #require(MessageAction.forkTarget(in: id))
            #expect(target.sessionID == session)
            #expect(target.messageIndex == 7)
        }

        @Test("a malformed or foreign wire id decodes to nothing")
        func forkTargetRejectsMalformedIDs() {
            #expect(MessageAction.forkTarget(in: "sm-copy-c2Vzcy1h") == nil)
            #expect(MessageAction.forkTarget(in: "fork-not-base64!.3") == nil)
            #expect(MessageAction.forkTarget(in: "fork-\(enc("sess-a")).-1") == nil)
            #expect(MessageAction.forkTarget(in: "fork-\(enc("sess-a"))") == nil)
            #expect(MessageAction.forkTarget(in: "fork-\(enc("sess-a")).x") == nil)
        }
    }

    // =======================================================================
    // MARK: - session fork
    //
    // "fork here" is a prefix copy, inclusive of the cut message, that opens
    // as its own session. The pure plan is pinned first; the store path is
    // pinned against a scratch FileSessionStore.
    // =======================================================================

    @Suite("session fork", .serialized)
    struct SessionForkTests {

        private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        private static func transcript() -> [Message] {
            [
                Message(role: .user, content: "first", createdAt: t0),
                Message(role: .assistant, content: "reply one", createdAt: t0.addingTimeInterval(1)),
                Message(role: .user, content: "second", createdAt: t0.addingTimeInterval(2)),
                Message(role: .assistant, content: "reply two", createdAt: t0.addingTimeInterval(3)),
                Message(role: .user, content: "third", createdAt: t0.addingTimeInterval(4)),
            ]
        }

        private static func source() -> Session {
            Session(
                id: "sess-src",
                createdAt: t0,
                updatedAt: t0,
                model: "test-model",
                provider: "test-provider",
                messages: transcript()
            )
        }

        @Test("the kept transcript is a prefix inclusive of the cut message")
        func forkKeepsInclusivePrefix() throws {
            let fork = try #require(SessionFork(
                session: Self.source(),
                throughUserMessageAt: 2,
                title: "first",
                workspaceKey: "main",
                categoryID: "cat-1"
            ))

            #expect(fork.messages.map(\.content) == ["first", "reply one", "second"],
                    "the fork must keep exactly what the reader had seen at the cut")
            #expect(fork.sourceID == "sess-src")
            #expect(fork.title == "↳ first")
            #expect(fork.model == "test-model")
            #expect(fork.provider == "test-provider")
            #expect(fork.workspaceKey == "main")
            #expect(fork.categoryID == "cat-1")
        }

        @Test("the materialized session records its parent")
        func forkRecordsLineage() throws {
            let fork = try #require(SessionFork(
                session: Self.source(), throughUserMessageAt: 4, title: "first"))
            let copy = fork.makeSession(now: Self.t0)
            #expect(copy.parentSessionID == "sess-src")
            #expect(copy.messages.count == 5)
            #expect(copy.messageCount == 5)
            #expect(copy.workspaceKey == nil)
            #expect(copy.createdAt == Self.t0)
        }

        @Test("a pinned source config travels with the fork")
        func forkInheritsPinnedConfig() throws {
            var source = Self.source()
            source.config = SessionConfigSnapshot(
                model: "pinned-model", provider: "openai", temperature: 0.2)
            let fork = try #require(SessionFork(
                session: source, throughUserMessageAt: 2, title: "first"))
            let copy = fork.makeSession(now: Self.t0)
            #expect(copy.config == source.config,
                    "a fork of a pinned session must keep running the pinned config")
        }

        @Test("a cut at a non-user message is refused")
        func refusesAssistantCut() {
            #expect(SessionFork(session: Self.source(), throughUserMessageAt: 1, title: "x") == nil,
                    "cutting at an assistant reply would keep a reply whose prompt is gone")
        }

        @Test("an out-of-range cut is refused")
        func refusesOutOfRangeCut() {
            #expect(SessionFork(session: Self.source(), throughUserMessageAt: 5, title: "x") == nil)
            #expect(SessionFork(session: Self.source(), throughUserMessageAt: -1, title: "x") == nil)
        }

        @Test("a long source title is clipped before the branch marker grows")
        func titleIsClipped() throws {
            let long = String(repeating: "word ", count: 40)
            let fork = try #require(SessionFork(
                session: Self.source(), throughUserMessageAt: 0, title: long))
            #expect(fork.title.hasPrefix("↳ "))
            #expect(fork.title.count <= 2 + 60 + 1)
        }

        @Test("forking persists the prefix, opens it, and leaves the source intact")
        func forkPersistsAndOpens() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-fork-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = FileSessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))

            let source = Self.source()
            try await store.create(source)

            var fixture = AppState.RenderFixture()
            fixture.sessions = [source]
            fixture.activeSessionID = source.id
            fixture.settings.sessionWorkspaces = [source.id: "main"]
            let app = AppState(renderFixture: fixture)
            await app.bindForkStore(store)

            let newID = try #require(await app.forkSession(source.id, throughUserMessageAt: 2))

            let copy = try #require(try await store.get(id: newID))
            #expect(copy.messages.map(\.content) == ["first", "reply one", "second"])
            #expect(copy.parentSessionID == source.id)
            #expect(copy.workspaceKey == "main")

            let opened = await app.activeSessionID
            let titles = await app.settings.sessionTitles
            let workspaces = await app.settings.sessionWorkspaces
            #expect(opened == newID, "a fork opens the new chat")
            #expect(titles[newID] == "↳ first")
            #expect(workspaces[newID] == "main")

            let untouched = try #require(try await store.get(id: source.id))
            #expect(untouched.messages.count == 5, "a fork is a branch, never a truncation")
        }

        @Test("forking without storage does nothing")
        func forkWithoutStoreIsANoOp() async {
            var fixture = AppState.RenderFixture()
            fixture.sessions = [Self.source()]
            fixture.activeSessionID = "sess-src"
            let app = AppState(renderFixture: fixture)
            let forked = await app.forkSession("sess-src", throughUserMessageAt: 2)
            #expect(forked == nil)
            let count = await app.sessions.count
            #expect(count == 1)
        }

        @Test("the rendered fork id dispatches through the msg-actions wire")
        func forkWireDispatches() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-fork-wire-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = FileSessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
            let source = Self.source()
            try await store.create(source)

            var fixture = AppState.RenderFixture()
            fixture.sessions = [source]
            fixture.activeSessionID = source.id
            let app = AppState(renderFixture: fixture)
            await app.bindForkStore(store)

            let router = EventRouter()
            let controller = Controller(app: app, push: { _ in })
            await controller.wireAll(router)

            // exactly the id the user message renders, addressed to exactly the
            // component the footer's boundary declares.
            let outcome = await router.dispatch(EventData(
                component: ComponentID("msg-actions"),
                event: "click",
                data: ["targetId": .string("fork-\(enc(source.id)).2")]
            ))
            #expect(outcome.fragments.isEmpty, "the handler pushes structure through the door")

            let opened = try #require(await app.activeSessionID)
            #expect(opened != source.id, "the click must open the fork, not the source")
            let fork = try #require(try await store.get(id: opened))
            #expect(fork.messages.map(\.content) == ["first", "reply one", "second"])
            #expect(fork.parentSessionID == source.id)
        }
    }
}

private extension AppState {
    /// bind the durable store the production init fills from the runtime.
    func bindForkStore(_ store: any SessionStore) {
        self.store = store
    }
}
