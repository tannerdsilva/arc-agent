import Testing
import ArcAgentCore
import WebUI
import WebUICore

@testable import ArcWebUI

// the cron group (Task 2.2): the scheduled-tasks boundary registers at the
// containers that carry it instead of once through `wireGroup_cron`. the panel
// head, each open category group and each non-empty group's task list register
// in `tasksPanel`, the selected task's control row in `tasksMainBody`;
// registration is id-keyed, so the create form's `data-component-id="tasks"`
// still routes its submit to the same body. the rest of `@WireGroup("cron")`
// (schedule-editor drafts, task search, deliver preset) stays boot-registered —
// those ids are not carried by a render-time container.
extension ArcWebUITestRoot {
    @Suite("Cron render", .serialized)
    struct CronRenderContractTests {

        private static let app: AppState = {
            var fixture = AppState.RenderFixture()
            fixture.settings.scheduledJobs = [
                CronJob(id: "job-1", name: "Morning digest", schedule: "every 15m",
                        prompt: "Summarise the inbox and send the digest.", isActive: true),
                CronJob(id: "job-2", name: "Nightly sweep", schedule: "0 3 * * *",
                        prompt: "Sweep the queue.", isActive: false),
            ]
            fixture.tasksSelectedID = "job-1"
            return AppState(renderFixture: fixture)
        }()

        private static func count(of needle: String, in html: String) -> Int {
            html.components(separatedBy: needle).count - 1
        }

        private static func renderPanel(router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await Self.app.tasksPanel().markup.html
            }
        }

        private static func renderMain(router: EventRouter) async -> String {
            await RenderContext.$current.withValue(
                RenderContext(router: router, session: .default)
            ) {
                await Self.app.tasksMain().markup.html
            }
        }

        @Test("the panel registers its boundaries and emits the routing pair")
        func panelRegistersAtRenderTime() async {
            let router = EventRouter()
            let html = await Self.renderPanel(router: router)

            #expect(router.handlerCount(in: .default) == 1,
                    "every panel boundary registers the same id, so one handler covers them all")
            // the panel head, each open category group and each non-empty
            // group's task list: seven sites for this fixture's two jobs.
            #expect(Self.count(of: "data-component-id=\"tasks\"", in: html) == 7,
                    "the panel head, each open category group and each non-empty task list must carry the boundary")
            #expect(Self.count(of: "data-event=\"click\"", in: html) == 7,
                    "the emitted controls must name the event the handler answers")
        }

        @Test("the main pane registers the selected task's control row")
        func mainRegistersAtRenderTime() async {
            let router = EventRouter()
            let html = await Self.renderMain(router: router)

            #expect(router.handlerCount(in: .default) == 1,
                    "the control row registers the same boundary id")
            #expect(Self.count(of: "data-component-id=\"tasks\"", in: html) == 1,
                    "only the control row carries the boundary in the main pane")
        }

        @Test("opening a task moves the selection and answers .refresh exactly once")
        func openTaskSignalsOnce() async {
            let router = EventRouter()
            _ = await Self.renderPanel(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("tasks"), event: "click",
                data: ["targetId": .string("task-open-job-2")]))

            #expect(outcome.fragments.isEmpty,
                    "the handler answers .refresh; the originating socket has nothing to write itself")
            #expect(await Self.app.tasksSelectedID == "job-2")
            #expect(outcome.isRefresh,
                    "one click is one structural signal — not zero and not two")
        }

        @Test("the new-task control opens the add form and signals once")
        func newTaskSignalsOnce() async {
            await Self.app.selectTaskJob("job-1")
            let router = EventRouter()
            _ = await Self.renderPanel(router: router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("tasks"), event: "click",
                data: ["targetId": .string("task-new")]))

            #expect(outcome.fragments.isEmpty)
            // the add form is a mode, not a selection change: `openTaskAdd`
            // resets the schedule draft and leaves the selection alone.
            #expect(await Self.app.tasksMode == .add)
            #expect(outcome.isRefresh)
        }

        @Test("wireAll alone no longer answers the tasks boundary")
        func wireAllDoesNotRegisterCron() async {
            await Self.app.selectTaskJob("job-1")
            let before = await Self.app.tasksSelectedID
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: { _ in })
            await controller.wireAll(router)

            let outcome = await router.dispatch(EventData(
                component: ComponentID("tasks"), event: "click",
                data: ["targetId": .string("task-open-job-2")]))

            #expect(outcome.fragments.isEmpty)
            #expect(await Self.app.tasksSelectedID == before,
                    "the boot wiring must not answer the tasks id any more; the render pass owns it")
            #expect(!outcome.isRefresh)
        }
    }
}
