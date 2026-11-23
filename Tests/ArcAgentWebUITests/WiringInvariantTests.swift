import Testing
@testable import ArcWebUI
import WebUICore

extension ArcWebUITestRoot {

    /// The invariant pin: every registration that the `Controller` installs is
    /// produced by `@Wired`/`@WireGroup` generation, never by a literal
    /// `wire(router, id:)` call site. The only literal-id `wire` calls that
    /// remain are the two documented escapes (`sidebar-plugin-toggle`) plus the
    /// `cat-pick` handler (it carries `contextmenu`, which no `HTMLEvent` case
    /// covers). Nav is no longer among them: it registers at render time
    /// through `controlAttributes` in `railButton`.
    ///
    /// This is the dispatch-fallback gate the plan pins at Wave 4
    /// (strict-dom's `registeredComponentIDs(in:)` + `WirePairingTests` are not
    /// yet available).
    ///
    /// The proof: drive `wireAll(router)` into a fresh router, then for every
    /// migrated group drive the group's own `wireGroup_<g>(router)` into a
    /// fresh router and assert the exact handler count. Deleting a `@Wired`
    /// annotation drops exactly one group's count, so this pin turns only one
    /// way. `wireAll` must register exactly 163: 161 generated + the two
    /// literal escapes `sidebar-plugin-toggle` + `cat-pick`. The merged tree
    /// carries more than the local line's count because upstream's kanban and
    /// settings surfaces stay wired here.
    ///
    /// The count is read from `hostHandlerCount`, not `handlerCount(in: .default)`:
    /// since no-webui 2.8.0 a registration made without a session lands in the
    /// router's HOST table (§22.1/D1), not in `.default`. `.default` is a real
    /// render session for tokenless pages, and counting it here would read zero
    /// for a fully wired host — a pin that cannot tell "nothing registered" from
    /// "everything registered in the other scope".
    ///
    /// The 12
    /// `nav-\(id)` registrations moved to the render pass (see
    /// `NavRoutingContractTests`), and toasts, insights, logs, the
    /// scheduled-tasks boundary, tools, the context pane and settings followed
    /// (`ToastRenderContractTests`, `InsightsRenderContractTests`,
    /// `LogsRenderContractTests`, `CronRenderContractTests`,
    /// `ToolsRenderContractTests`, `CtxpaneRenderContractTests`,
    /// `SettingsRenderContractTests`), which is why the count sits 44 below the
    /// upstream line's 195 rather than at it.
    @Suite("wiring invariant", .serialized)
    struct WiringInvariantTests {

        private static let push: @Sendable ([FragmentUpdate]) async -> Void = { _ in }

        /// records the batches a handler hands the door.
        private actor Door {
            private(set) var batches: [[FragmentUpdate]] = []
            nonisolated var push: @Sendable ([FragmentUpdate]) async -> Void {
                { [weak self] updates in await self?.record(updates) }
            }
            private func record(_ updates: [FragmentUpdate]) { batches.append(updates) }
        }

        /// One shared `AppState` for the whole suite. Each test builds its own
        /// router and controller, but reusing a single `AppState` avoids the
        /// per-test `AsyncHTTPClient` teardown trap
        /// (`Fatal error: Client not shut down before the deinit`) that a
        /// fresh `AppState` per test would hit on suite teardown.
        private static let app = AppState(renderFixture: .init())

        @Test("every chat handler is registered after wireGroup_chat")
        func chatGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_chat(router)
            #expect(router.hostHandlerCount == 44, "chat group registration drifted")
        }

        // settings register at render time across `settingsMain`'s sections,
        // so there is no boot group to count here: see
        // `SettingsRenderContractTests`.

        @Test("every settings_admin handler is registered after wireGroup_settings_admin")
        func settingsAdminGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_settings_admin(router)
            #expect(router.hostHandlerCount == 40, "settings_admin group registration drifted")
        }

        @Test("every skills handler is registered after wireGroup_skills")
        func skillsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_skills(router)
            #expect(router.hostHandlerCount == 15, "skills group registration drifted")
        }

        @Test("every profiles handler is registered after wireGroup_profiles")
        func profilesGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_profiles(router)
            #expect(router.hostHandlerCount == 11, "profiles group registration drifted")
        }

        @Test("every mcp handler is registered after wireGroup_mcp")
        func mcpGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_mcp(router)
            #expect(router.hostHandlerCount == 8, "mcp group registration drifted")
        }

        @Test("every chatmenu handler is registered after wireGroup_chatmenu")
        func chatmenuGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_chatmenu(router)
            #expect(router.hostHandlerCount == 6, "chatmenu group registration drifted")
        }

        @Test("every workspaces handler is registered after wireGroup_workspaces")
        func workspacesGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_workspaces(router)
            #expect(router.hostHandlerCount == 6, "workspaces group registration drifted")
        }

        @Test("every queue handler is registered after wireGroup_queue")
        func queueGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_queue(router)
            #expect(router.hostHandlerCount == 6, "queue group registration drifted")
        }

        // tools register at render time in `toolsPanel`, so there is no boot
        // group to count here: see `ToolsRenderContractTests`.

        @Test("every plugins handler is registered after wireGroup_plugins")
        func pluginsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_plugins(router)
            #expect(router.hostHandlerCount == 2, "plugins group registration drifted")
        }

        // logs register at render time in `logsPanel`, so there is no boot
        // group to count here: see `LogsRenderContractTests`.

        // toasts register at render time in `toastsShell`, so there is no boot
        // group to count here: see `ToastRenderContractTests` (added with the
        // group).

        // insights register at render time in `insightsPanel`, so there is no
        // boot group to count here: see `InsightsRenderContractTests`.

        @Test("every todos handler is registered after wireGroup_todos")
        func todosGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_todos(router)
            #expect(router.hostHandlerCount == 1, "todos group registration drifted")
        }

        @Test("every cron handler is registered after wireGroup_cron")
        func cronGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_cron(router)
            #expect(router.hostHandlerCount == 10,
                    "cron group: 8 schedule-editor change wires + task-search input + deliver preset — `tasks` itself registers at render time through `tasksBoundary`")
        }

        @Test("every regen handler is registered after wireGroup_regen")
        func regenGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_regen(router)
            #expect(router.hostHandlerCount == 1, "regen group registration drifted")
        }

        @Test("every message_actions handler is registered after wireGroup_message_actions")
        func messageActionsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_message_actions(router)
            #expect(router.hostHandlerCount == 1, "message_actions group registration drifted")
        }

        @Test("wireAll registers exactly 166 handlers (kanban cards wires included)")
        func wireAllRegistersExactly166() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            await controller.wireAll(router)

            let count = router.hostHandlerCount
            #expect(
                count == 166,
                "wireAll must register exactly 166 handlers after the cards-tab wire: the remote render-time toast/panel handlers no longer boot-wire, while the kanban-agent wires (new-board form + two close buttons + the 3 subcard-split wires) remain, got \(count)")
        }

        /// A non-listed id has no handler: the router answers empty fragments.
        @Test("an unregistered id dispatches to no handler")
        func unregisteredIdDispatchesEmpty() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            await controller.wireAll(router)

            let outcome = await router.dispatch(
                EventData(component: ComponentID("no-such-id"), event: "click", data: [:]))
            #expect(outcome.fragments.isEmpty,
                    "an unregistered id must not answer — the allowlist leaks nothing")
        }

        /// Prove the pin turns: `chat-new` is @Wired in source, so it answers.
        /// The ratchet only turns one direction — `@Wired` ids cannot be untyped.
        ///
        /// "Answers" is an outcome now (no-webui 2.12.0), not a push: the
        /// handler's return type picks the registration, so `chat-new` declares
        /// `HandlerOutcome` and answers `.refresh` — the server re-renders the
        /// dispatch session's page and the edge is never asked.
        @Test("the ratchet turns one direction: @Wired ids cannot be untyped")
        func ratchetTurnsOneDirection() async throws {
            let door = Door()
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: door.push)
            await controller.wireAll(router)

            let outcome = await router.dispatch(
                EventData(component: ComponentID("chat-new"), event: "click", data: [:]))
            #expect(outcome.isRefresh,
                    "chat-new answers .refresh: the server re-renders the dispatch session's page")
            #expect(await door.batches.isEmpty,
                    "a handler's structure is an outcome, not a push — the edge is not asked")
            #expect(outcome.fragments.isEmpty,
                    "the refresh crosses the outcome, not the socket — the server has nothing to write")
        }

        /// The upload repaint seam: an HTTP upload returns no `FragmentUpdate`,
        /// and 2.11.0's zone dispatches `upload-complete` on the workspace-panel
        /// zone (`ws-drop`) or on the composer form. The panel handler must be
        /// registered, carry no payload work, and answer exactly one refresh —
        /// the tree is re-rendered by the server, never by the client.
        @Test("ws-drop asks the door for a render and writes nothing on the socket")
        func workspaceUploadAsksForRender() async throws {
            let door = Door()
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: door.push)
            await controller.wireAll(router)

            let outcome = await router.dispatch(
                EventData(component: ComponentID("ws-drop"),
                          event: .custom("upload-complete"),
                          data: ["path": .string("notes.txt"), "bytes": .string("3")]))
            #expect(outcome.fragments.isEmpty,
                    "the refresh crosses the outcome, not the originating socket")
            #expect(outcome.isRefresh,
                    "a landed panel upload must ask for exactly one render")
            #expect(await door.batches.isEmpty,
                    "the refresh is the server's, not the edge's — nothing is pushed")
        }
    }
}
