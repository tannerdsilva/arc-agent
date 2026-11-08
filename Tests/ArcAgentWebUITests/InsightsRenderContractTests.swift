import Testing
import WebUI
import WebUICore

@testable import ArcWebUI

// the insights group (Task 2.2): the range selector registers during the render
// pass instead of through `wireGroup_insights`. the panel is rendered here the
// way `WebUIServer` renders it — inside a `RenderContext` — and the dispatch is
// pinned to both halves: the state move and the one structural signal.
extension ArcWebUITestRoot {
    @Suite("Insights render", .serialized)
    struct InsightsRenderContractTests {

        private actor Door {
            private(set) var count = 0
            nonisolated var signal: @Sendable () async -> Void {
                { [weak self] in await self?.nudge() }
            }
            private func nudge() { count += 1 }
        }

        private static let app = AppState(renderFixture: .init())

        private static func renderPanel(router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await Self.app.insightsPanel().markup.html
            }
        }

        @Test("the range selector registers and emits the routing pair at render time")
        func selectorRegistersAtRenderTime() async {
            let router = EventRouter()
            let html = await Self.renderPanel(router: router)

            #expect(router.handlerCount(in: .default) == 1,
                    "the render pass must register the range selector")
            #expect(html.contains("data-component-id=\"ins-range\""))
            #expect(html.contains("data-event=\"change\""),
                    "the emitted control must name the event the handler answers")
        }

        @Test("changing the range moves the window and signals the door exactly once")
        func rangeChangeSignalsOnce() async {
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            _ = await Self.renderPanel(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("ins-range"), event: "change",
                data: ["value": .string("7")]))

            #expect(outcome.fragments.isEmpty,
                    "the handler signals the door; the originating socket has nothing to write")
            #expect(await Self.app.insightsRangeDays == 7,
                    "the selector's value must land in the range the panel renders")
            #expect(await door.count == 1,
                    "one change is one structural signal — not zero and not two")
        }

        @Test("wireAll alone no longer answers the range selector")
        func wireAllDoesNotRegisterInsights() async {
            let before = await Self.app.insightsRangeDays
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: { _ in })
            await controller.wireAll(router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("ins-range"), event: "change",
                data: ["value": .string("365")]))

            #expect(outcome.fragments.isEmpty)
            #expect(await Self.app.insightsRangeDays == before,
                    "the boot wiring must not answer the range id any more; the render pass owns it")
            #expect(await door.count == 0)
        }
    }
}
