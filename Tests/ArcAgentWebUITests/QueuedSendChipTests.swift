import ArcAgentCore
import Foundation
import Testing
import WebUICore
import WebUIState

@testable import ArcWebUI

/// The queue chip, end to end (audit 2026-11-01, wave 3): a message submitted
/// while this chat's turn is running must (a) take the queue branch, and
/// (b) reach the page — the chip renders in the composer region and the push
/// door ships it. The live audit could not catch a true live-turn window
/// through the harness; this suite drives the real handler, the real edge and
/// the real differ instead.
@Suite("Queued send chip delivery", .serialized)
struct QueuedSendChipTests {

    /// The composer submit event for `text`.
    private static func submitEvent(_ text: String) -> EventData {
        EventData(
            component: ComponentID("composer-form"),
            event: "submit",
            data: ["composer-input": .string(text)])
    }

    /// A fixture whose active session has one past exchange, so the composer
    /// and transcript render fully.
    private static func fixture() -> AppState.RenderFixture {
        var f = AppState.RenderFixture()
        f.activeSessionID = "sess-a"
        f.sessions = [
            Session(id: "sess-a", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Probe chat",
                    messageCount: 2,
                    messages: [
                        Message(role: .user, content: "hello"),
                        Message(role: .assistant, content: "hi"),
                    ]),
        ]
        return f
    }

    /// A tiny thread-safe box standing in for the wire (the push door
    /// broadcasts here).
    private final class WireBox: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[FragmentUpdate]] = []
        func record(_ b: [FragmentUpdate]) {
            lock.lock(); defer { lock.unlock() }
            batches.append(b)
        }
        var flat: [FragmentUpdate] {
            lock.lock(); defer { lock.unlock() }
            return batches.flatMap { $0 }
        }
    }

    @Test("a submit during a live turn queues and renders the chip")
    func queuedSubmitRendersChip() async {
        var f = Self.fixture()
        // The live turn the submit must queue behind: `isTurnActive` reads
        // `activeTurns[sessionID]`, so seed it through the fixture seam.
        f.activeTurns = ["sess-a": LiveTurn(sessionID: "sess-a", userText: "hi", attachments: [])]
        let app = AppState(renderFixture: f)
        let box = WireBox()
        let edge = PushEdge(
            differ: PageDiffer(policy: PushEdge.livePolicy),
            render: { [app] in await app.appShell().markup.html },
            broadcast: { [box] in await box.record($0) })
        edge.seed(await app.appShell().markup.html)

        let router = EventRouter()
        let controller = Controller(app: app, push: { await edge.push($0) })
        await controller.wireAll(router)

        // The composer submit crosses the real @Wired handler, dispatched the
        // way the engine would deliver it.
        _ = await router.dispatch(Self.submitEvent("queued while running"))

        // (a) The queue branch stored the text server-side.
        let queued = await app.queuedSends["sess-a"]
        #expect(queued?.count == 1, "the submit during a live turn must be queued")

        // (b) The chip reached the wire — some frame's bytes carry it.
        let chipFrame = box.flat.first { $0.html.contains("queued-sends") }
        #expect(chipFrame != nil, "no frame shipped the queue chip — the page never learns a message was queued")
    }
}
extension QueuedSendChipTests {

    /// UX-04 consistency (wave 3): the direct send path consumes the composer
    /// draft inside `runTurn` (`noteSubmittedDraft` + clear); the queue branch
    /// returns before any of that. A queued message that leaves its text in
    /// the composer is one Enter away from a double send.
    @Test("a queued submit consumes the composer draft like a direct send")
    func queuedSubmitConsumesDraft() async {
        var f = Self.fixture()
        f.activeTurns = ["sess-a": LiveTurn(sessionID: "sess-a", userText: "hi", attachments: [])]
        f.formValues = ["composer-input": "queued text"]
        let app = AppState(renderFixture: f)
        let box = WireBox()
        let edge = PushEdge(
            differ: PageDiffer(policy: PushEdge.livePolicy),
            render: { [app] in await app.appShell().markup.html },
            broadcast: { [box] in await box.record($0) })
        edge.seed(await app.appShell().markup.html)

        let router = EventRouter()
        let controller = Controller(app: app, push: { await edge.push($0) })
        await controller.wireAll(router)

        // The engine delivers the composer's current value through the form
        // submit; a draft for this session also exists server-side (a saved
        // reload draft).
        await app.storeComposerDraft("queued text", sessionID: "sess-a")
        _ = await router.dispatch(Self.submitEvent("queued text"))

        let queued = await app.queuedSends["sess-a"]
        #expect(queued?.count == 1, "the message must be queued")

        // The draft must be consumed: the server-side draft is cleared and the
        // text is registered as submitted, so the ghost-draft guard protects
        // the exact same text from a trailing input frame.
        let draft = await app.settings.composerDrafts["sess-a"]
        #expect(draft?.isEmpty != false, "the queued text must not stay in the draft — one Enter away from a double send")
    }
}
