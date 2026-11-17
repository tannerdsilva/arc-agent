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

            // the router keys by id: one toolset toggle body, one tool-row
            // boundary body, and one per-tool switch body (T6) — however many
            // controls carry them in the emitted page.
            #expect(router.handlerCount(in: .default) == 3,
                    "the render pass must register the toolset toggle, the tool row and the per-tool switch")
            #expect(Self.count(of: "data-component-id=\"tools-toggle\"", in: html) == 2,
                    "each toolset must carry the toggle's routing id")
            #expect(Self.count(of: "data-component-id=\"tool-list\"", in: html) == 3,
                    "each rendered tool row must carry the boundary id")
            // 2 toolset toggles + 2 live per-tool switches. the third tool row
            // belongs to the disabled toolset, so its switch is inert: it
            // carries `disabled` instead of a routing pair, and says why.
            #expect(Self.count(of: "data-event=\"change\"", in: html) == 4)
            #expect(Self.count(of: "data-event=\"click\"", in: html) == 3)
            #expect(Self.count(of: " disabled=\"\"", in: html) == 1,
                    "the row whose toolset is off must render one inert switch, not a live one")
            #expect(Self.count(of: "aria-disabled=\"true\"", in: html) == 2,
                    "that row greys itself (row + switch) rather than disappearing")
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

        @Test("a per-tool switch writes the per-tool list and leaves the toolset list alone")
        func toolToggleWritesOnlyThePerToolList() async {
            let router = EventRouter()
            // a fixture of its own: this test writes a list the shared fixture
            // does not start from, so it cannot depend on what ran before it.
            var fixture = AppState.RenderFixture()
            fixture.toolsets = [("file", [
                StubTool(name: "read_file", toolset: "file", emoji: "📄"),
                StubTool(name: "write_file", toolset: "file", emoji: "✍️"),
            ])]
            let app = AppState(renderFixture: fixture)
            let html = await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await app.toolsPanel().markup.html
            }
            #expect(html.contains("data-component-id=\"tool-toggle\""),
                    "the row switch must carry its routing pair")

            let before = await app.arcConfig.tools.disabledToolsets
            let outcome = await router.dispatch(EventData(
                component: ComponentID("tool-toggle"), event: "change",
                data: ["targetId": .string("tl-toggle-\(enc("write_file"))"),
                       "checked": .bool(false)]))

            let after = await app.arcConfig.tools.disabledTools
            #expect(outcome.fragments.isEmpty)
            #expect(after == ["write_file"],
                    "the switch writes the per-tool deny list")
            #expect(await app.arcConfig.tools.disabledToolsets == before,
                    "one tool switched off must not touch the toolset switch")
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
