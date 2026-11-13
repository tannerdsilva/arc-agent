import Testing
import ArcAgentCore
import WebUI
import WebUICore

@testable import ArcWebUI

// the tools group (Task 2.2): the tool-row boundary and the toolset toggle
// register during the render pass instead of through `wireGroup_tools`. the
// toggle is an `ArcSwitch`, so its pair travels through `extraAttributes`;
// the row boundary was a bare `data-component-id` and now also emits
// `data-event="click"` — that is the declared parity delta in `tools-panel`.
extension ArcWebUITestRoot {
    @Suite("tools render", .serialized)
    struct ToolsRenderContractTests {

        private static let app: AppState = {
            var fixture = AppState.RenderFixture()
            fixture.toolsets = [
                ("file", [
                    StubTool(name: "read_file", toolset: "file", emoji: "📄"),
                    StubTool(name: "write_file", toolset: "file", emoji: "✍️"),
                ]),
                ("terminal", [StubTool(name: "run_command", toolset: "terminal")]),
            ]
            fixture.arcConfig.tools.disabledToolsets = ["terminal"]
            return AppState(renderFixture: fixture)
        }()

        private static func renderPanel(router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await Self.app.toolsPanel().markup.html
            }
        }

        private static func count(of needle: String, in html: String) -> Int {
            html.components(separatedBy: needle).count - 1
        }

        @Test("the row boundary and the toolset toggle register at render time")
        func controlsRegisterAtRenderTime() async {
            let router = EventRouter()
            let html = await Self.renderPanel(router: router)

            // the router keys by id: one toggle body and one row body, however
            // many controls carry them in the emitted page.
            #expect(router.handlerCount(in: .default) == 2,
                    "the render pass must register the toolset toggle and the tool row")
            #expect(Self.count(of: "data-component-id=\"tools-toggle\"", in: html) == 2,
                    "each toolset must carry the toggle's routing id")
            #expect(Self.count(of: "data-component-id=\"tool-list\"", in: html) == 3,
                    "each rendered tool row must carry the boundary id")
            #expect(Self.count(of: "data-event=\"change\"", in: html) == 2)
            #expect(Self.count(of: "data-event=\"click\"", in: html) == 3)
        }

        @Test("a tool row click selects the tool and answers .refresh exactly once")
        func rowClickSignalsOnce() async {
            let router = EventRouter()
            _ = await Self.renderPanel(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("tool-list"), event: "click",
                data: ["targetId": .string("tl-open-\(enc("write_file"))")]))

            #expect(outcome.fragments.isEmpty,
                    "the handler answers .refresh; the originating socket has nothing to write itself")
            #expect(await Self.app.selectedTool == "write_file",
                    "the row's encoded tool name must land in the selected tool")
            #expect(outcome.isRefresh,
                    "one click is one structural signal — not zero and not two")
        }

        @Test("a toolset toggle writes the policy and answers .refresh exactly once")
        func toggleSignalsOnce() async {
            let router = EventRouter()
            _ = await Self.renderPanel(router: router)

            let before = await Self.app.arcConfig.tools.disabledToolsets
            let outcome = await router.dispatch(EventData(
                component: ComponentID("tools-toggle"), event: "change",
                data: ["targetId": .string("ts-\(enc("terminal"))"),
                       "checked": .bool(true)]))

            let after = await Self.app.arcConfig.tools.disabledToolsets
            #expect(outcome.fragments.isEmpty)
            #expect(!after.contains("terminal"),
                    "enabling a disabled toolset must remove it from the disabled list")
            #expect(after == before.filter { $0 != "terminal" },
                    "the toggle must leave every other toolset policy untouched")
            #expect(outcome.isRefresh,
                    "one change is one structural signal — not zero and not two")
        }

        @Test("wireAll alone no longer answers either tools id")
        func wireAllDoesNotRegisterTools() async {
            let beforeTool = await Self.app.selectedTool
            let beforeDisabled = await Self.app.arcConfig.tools.disabledToolsets
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: { _ in })
            await controller.wireAll(router)

            let row = await router.dispatch(EventData(
                component: ComponentID("tool-list"), event: "click",
                data: ["targetId": .string("tl-open-\(enc("read_file"))")]))
            let toggle = await router.dispatch(EventData(
                component: ComponentID("tools-toggle"), event: "change",
                data: ["targetId": .string("ts-\(enc("file"))"),
                       "checked": .bool(false)]))

            #expect(row.fragments.isEmpty)
            #expect(toggle.fragments.isEmpty)
            #expect(await Self.app.selectedTool == beforeTool,
                    "the boot wiring must not answer the row id any more; the render pass owns it")
            #expect(await Self.app.arcConfig.tools.disabledToolsets == beforeDisabled,
                    "the boot wiring must not answer the toggle id any more; the render pass owns it")
            #expect(!row.isRefresh, "the boot wiring must not answer the row id any more; the render pass owns it")
            #expect(!toggle.isRefresh, "the boot wiring must not answer the toggle id any more; the render pass owns it")
        }
    }
}
