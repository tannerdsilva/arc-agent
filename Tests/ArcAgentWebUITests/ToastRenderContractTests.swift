import Testing
import WebUI
import WebUICore

@testable import ArcWebUI

// the first Task 2.2 group (toasts): the container registers during the render
// pass instead of through `wireGroup_toasts`. the toast's own id travels as
// `targetId`, so one stable container id covers every row — the pattern the
// remaining groups follow.
extension ArcWebUITestRoot {
    @Suite("Toast render", .serialized)
    struct ToastRenderContractTests {

        private actor Door {
            private(set) var count = 0
            nonisolated var signal: @Sendable () async -> Void {
                { [weak self] in await self?.nudge() }
            }
            private func nudge() { count += 1 }
        }

        private static let app = AppState(renderFixture: .init())

        private static func renderShell(router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await Self.app.toastsShell().markup.html
            }
        }

        @Test("the toast container registers and emits the routing pair at render time")
        func containerRegistersAtRenderTime() async {
            let router = EventRouter()
            let html = await Self.renderShell(router: router)

            #expect(router.handlerCount(in: .default) == 1,
                    "the render pass must register the toast container")
            #expect(html.contains("data-component-id=\"toast-dismiss\""))
            #expect(html.contains("data-event=\"click\""))
        }

        @Test("dismissing a toast signals the door exactly once")
        func dismissSignalsOnce() async {
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            _ = await Self.renderShell(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("toast-dismiss"), event: "click",
                data: ["targetId": .string("t-1")]))

            #expect(outcome.fragments.isEmpty)
            #expect(await door.count == 1)
        }

        @Test("wireAll alone no longer answers the toast container")
        func wireAllDoesNotRegisterToast() async {
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: { _ in })
            await controller.wireAll(router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("toast-dismiss"), event: "click",
                data: ["targetId": .string("t-1")]))

            #expect(outcome.fragments.isEmpty)
            #expect(await door.count == 0,
                    "the boot wiring must not answer a toast id any more; the render pass owns it")
        }
    }
}
