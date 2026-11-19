import Testing
import ArcAgentCore
import WebUI
import WebUICore

@testable import ArcWebUI

// the logs group (Task 2.2): both controls — the chip boundary that answers
// `log-filter` and the clear button — register during the render pass instead
// of through `wireGroup_logs`. the clear button is an `ArcButton`, so its pair
// travels through `extraAttributes`; that is the declared parity delta (one
// `data-event="click"` on `#log-clear` in `logs-panel`).
extension ArcWebUITestRoot {
    @Suite("Logs render", .serialized)
    struct LogsRenderContractTests {

        private static let app = AppState(renderFixture: .init())

        private static func renderPanel(router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await Self.app.logsPanel().markup.html
            }
        }

        @Test("both log controls register and emit the routing pair at render time")
        func controlsRegisterAtRenderTime() async {
            let router = EventRouter()
            let html = await Self.renderPanel(router: router)

            #expect(router.handlerCount(in: .default) == 2,
                    "the render pass must register the filter boundary and the clear button")
            #expect(html.contains("data-component-id=\"log-filter\""),
                    "the chip boundary must carry the id its handler registered")
            #expect(html.contains("data-component-id=\"log-clear\""),
                    "the clear button must carry the id its handler registered")
            #expect(html.contains("data-event=\"click\""),
                    "the emitted controls must name the event the handlers answer")
        }

        @Test("a chip click moves the filter and answers .refresh exactly once")
        func filterClickSignalsOnce() async {
            let router = EventRouter()
            _ = await Self.renderPanel(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("log-filter"), event: "click",
                data: ["targetId": .string("log-filter-warn")]))

            #expect(outcome.fragments.isEmpty,
                    "the handler answers .refresh; the originating socket has nothing to write itself")
            #expect(await Self.app.logFilter == "warn")
            #expect(outcome.isRefresh,
                    "one click is one structural signal — not zero and not two")
        }

        @Test("a clear click empties the buffer and answers .refresh exactly once")
        func clearClickSignalsOnce() async {
            LogCollector.shared.clear()
            LogCollector.shared.append(level: .info, text: "line before the clear")
            let router = EventRouter()
            _ = await Self.renderPanel(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("log-clear"), event: "click", data: [:]))

            #expect(outcome.fragments.isEmpty)
            #expect(LogCollector.shared.count == 0,
                    "the clear button must still clear the process-wide buffer")
            #expect(outcome.isRefresh)
        }

        @Test("wireAll alone no longer answers either log id")
        func wireAllDoesNotRegisterLogs() async {
            LogCollector.shared.clear()
            LogCollector.shared.append(level: .info, text: "line the boot wiring must not clear")
            let before = await Self.app.logFilter
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: { _ in })
            await controller.wireAll(router)

            let filter = await router.dispatch(EventData(
                component: ComponentID("log-filter"), event: "click",
                data: ["targetId": .string("log-filter-error")]))
            let clear = await router.dispatch(EventData(
                component: ComponentID("log-clear"), event: "click", data: [:]))

            #expect(filter.fragments.isEmpty)
            #expect(clear.fragments.isEmpty)
            #expect(await Self.app.logFilter == before,
                    "the boot wiring must not answer the filter id any more; the render pass owns it")
            #expect(LogCollector.shared.count == 1,
                    "the boot wiring must not answer the clear id any more; the render pass owns it")
            #expect(!filter.isRefresh, "the boot wiring must not answer the filter id any more; the render pass owns it")
            #expect(!clear.isRefresh, "the boot wiring must not answer the clear id any more; the render pass owns it")
        }
    }
}
