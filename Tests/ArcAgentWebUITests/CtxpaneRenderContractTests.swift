import Testing
import Foundation
import ArcAgentCore
import WebUI
import WebUICore

@testable import ArcWebUI

// the ctxpane group (Task 2.2): the context-pane boundary registers during the
// render pass at both sites that carry it — the ring in `ctxIndicatorHTML` and
// the card in `contextPaneHTML` — instead of through `wireGroup_ctxpane`. both
// sites install the same `AppState.contextPaneBoundary` body, so registration
// is repeated but the handler is not.
extension ArcWebUITestRoot {
    @Suite("ctxpane render", .serialized)
    struct CtxpaneRenderContractTests {

        private actor Door {
            private(set) var count = 0
            nonisolated var signal: @Sendable () async -> Void {
                { [weak self] in await self?.nudge() }
            }
            private func nudge() { count += 1 }
        }

        private static let app = AppState(renderFixture: .init())

        private static let session = Session(
            id: "sess-ctx", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), title: "Context",
            messages: [Message(role: .user, content: "hello")])

        private static func renderRing(router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await Self.app.ctxIndicatorHTML(Self.session).markup.html
            }
        }

        @Test("the context ring registers and emits the routing pair at render time")
        func ringRegistersAtRenderTime() async {
            let router = EventRouter()
            let html = await Self.renderRing(router: router)

            #expect(router.handlerCount(in: .default) == 1,
                    "the render pass must register the context-pane boundary")
            #expect(html.contains("data-component-id=\"ctxpane\""),
                    "the ring must carry the id its handler registered")
            #expect(html.contains("data-event=\"click\""),
                    "the emitted control must name the event the handler answers")
        }

        @Test("a ring click asks the door for exactly one structural signal")
        func ringClickSignalsOnce() async {
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            _ = await Self.renderRing(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("ctxpane"), event: "click", data: [:]))

            #expect(outcome.fragments.isEmpty,
                    "the handler signals the door; the originating socket has nothing to write")
            #expect(await door.count == 1,
                    "one ring click is one structural signal — not zero and not two")
        }

        @Test("a click inside the card is inert and signals nothing")
        func cardClickIsInert() async {
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            _ = await Self.renderRing(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("ctxpane"), event: "click",
                data: ["targetId": .string("ctx-pane-card")]))

            #expect(outcome.fragments.isEmpty)
            #expect(await door.count == 0,
                    "clicks inside the card content must not ask for a render")
        }

        @Test("wireAll alone no longer answers the context pane id")
        func wireAllDoesNotRegisterCtxpane() async {
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: { _ in })
            await controller.wireAll(router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("ctxpane"), event: "click", data: [:]))

            #expect(outcome.fragments.isEmpty)
            #expect(await door.count == 0,
                    "the boot wiring must not answer the ctxpane id any more; the render pass owns it")
        }
    }
}
