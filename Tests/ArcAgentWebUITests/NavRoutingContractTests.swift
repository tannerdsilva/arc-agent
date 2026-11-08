import Testing
import WebUI
import WebUICore

@testable import ArcWebUI

// the nav pilot (Task 2.1): the rail's controls register during the render pass
// instead of through a boot loop over `railTabIDs()`. this suite pins both
// halves — the emitted routing attributes and the dispatch that reaches the
// app's structural signal — and that the boot wiring no longer answers a nav id.
//
// registration only happens inside a `RenderContext`, which is what the server
// establishes around every page render and what this suite establishes by hand.
// outside one the same control emits its attributes without registering; that is
// the framework's documented fragment-re-render behaviour, not a skip.
//
// one shared app: `AppState` owns an `AsyncHTTPClient`, and a fresh instance per
// test trips its shutdown contract at suite teardown (see `WiringInvariantTests`).
extension ArcWebUITestRoot {
    @Suite("Nav routing", .serialized)
    struct NavRoutingContractTests {

        private actor Door {
            private(set) var count = 0
            nonisolated var signal: @Sendable () async -> Void {
                { [weak self] in await self?.nudge() }
            }
            private func nudge() { count += 1 }
        }

        private static let app = AppState(renderFixture: .init())

        private static func renderRail(router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await Self.app.appShell().markup.html
            }
        }

        @Test("the rail registers one handler per tab and emits the routing attributes")
        func railRegistersAtRenderTime() async {
            let router = EventRouter()
            let html = await Self.renderRail(router: router)
            let expected = await Self.app.railTabIDs().count + 1  // + the toast container (Task 2.2, group 1)

            #expect(router.handlerCount(in: .default) == expected,
                    "the render pass must register every rail tab, got \(router.handlerCount(in: .default)) for \(expected) tabs")
            #expect(html.contains("data-component-id=\"nav-chat\""),
                    "the rail button must carry the id its handler registered")
            #expect(html.contains("data-event=\"click\""),
                    "the emitted control must name the event the handler answers")
        }

        @Test("a rendered nav control moves the tab and asks the door exactly once")
        func navDispatchMovesTabAndSignals() async {
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            _ = await Self.renderRail(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("nav-settings"), event: "click", data: [:]))

            #expect(outcome.fragments.isEmpty,
                    "the handler signals the door; the originating socket has nothing to write")
            #expect(await Self.app.activeTabID == "settings")
            #expect(await door.count == 1,
                    "one click is one structural signal — not zero and not two")
        }

        @Test("wireAll alone no longer answers a nav id")
        func wireAllDoesNotRegisterNav() async {
            let before = await Self.app.activeTabID
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: { _ in })
            await controller.wireAll(router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("nav-chat"), event: "click", data: [:]))

            #expect(outcome.fragments.isEmpty)
            #expect(await Self.app.activeTabID == before,
                    "the boot wiring must not answer a nav id any more; the render pass owns it")
        }
    }
}
