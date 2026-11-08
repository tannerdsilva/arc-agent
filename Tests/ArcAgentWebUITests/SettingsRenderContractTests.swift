import Testing
import WebUI
import WebUICore

@testable import ArcWebUI

// the settings group (Task 2.2): the 24 handlers register where their controls
// are rendered in `settingsMain`'s sections instead of through
// `wireGroup_settings`. one representative control is enough here — the theme
// grid (`.control`) and the MoA switch (`ArcSwitch.extraAttributes`) — plus the
// two properties every site must keep: one structural signal per dispatch and a
// bare `wireAll` that no longer answers the id.
extension ArcWebUITestRoot {
    @Suite("settings render", .serialized)
    struct SettingsRenderContractTests {

        private actor Door {
            private(set) var count = 0
            nonisolated var signal: @Sendable () async -> Void {
                { [weak self] in await self?.nudge() }
            }
            private func nudge() { count += 1 }
        }

        private static let app = AppState(renderFixture: .init())

        private static func renderSettings(router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await Self.app.settingsMain().markup.html
            }
        }

        @Test("the theme grid and the MoA switch register and emit their pairs at render time")
        func controlsRegisterAtRenderTime() async {
            let router = EventRouter()
            let html = await Self.renderSettings(router: router)

            #expect(router.handlerCount(in: .default) >= 2,
                    "the render pass must register the settings controls it emitted")
            #expect(html.contains("data-component-id=\"theme-pick\" data-event=\"click\""),
                    "the theme grid must carry the id and event its handler registered")
            #expect(html.contains("data-component-id=\"set-moa\" data-event=\"change\""),
                    "the MoA switch must carry the id and event its handler registered")
        }

        @Test("choosing a theme moves the setting and signals the door exactly once")
        func themePickSignalsOnce() async {
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            _ = await Self.renderSettings(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("theme-pick"), event: "click",
                data: ["targetId": .string("thm-dark")]))

            let after = await Self.app.settings.theme
            #expect(outcome.fragments.isEmpty,
                    "the handler signals the door; the originating socket has nothing to write")
            #expect(after == "dark", "the chosen theme must land in settings.theme")
            #expect(await door.count == 1,
                    "one click is one structural signal — not zero and not two")
        }

        @Test("wireAll alone no longer answers the theme grid id")
        func wireAllDoesNotRegisterSettings() async {
            let before = await Self.app.settings.theme
            let door = Door()
            await Self.app.installStructuralSignal(door.signal)
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: { _ in })
            await controller.wireAll(router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("theme-pick"), event: "click",
                data: ["targetId": .string("thm-light")]))

            #expect(outcome.fragments.isEmpty)
            #expect(await Self.app.settings.theme == before,
                    "the boot wiring must not answer the theme id any more; the render pass owns it")
            #expect(await door.count == 0)
        }
    }
}
