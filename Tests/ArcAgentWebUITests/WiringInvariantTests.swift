import Testing
@testable import ArcWebUI
import WebUICore

extension ArcWebUITestRoot {

    /// The invariant pin: every registration that the `Controller` installs is
    /// produced by `@Wired`/`@WireGroup` generation, never by a literal
    /// `wire(router, id:)` call site. The only literal-id `wire` calls that
    /// remain are the two documented dynamic escapes (`nav-\(id)` and
    /// `sidebar-plugin-toggle`) plus the `cat-pick` handler (it carries
    /// `contextmenu`, which no `HTMLEvent` case covers).
    ///
    /// This is the dispatch-fallback gate the plan pins at Wave 4
    /// (strict-dom's `registeredComponentIDs(in:)` + `WirePairingTests` are not
    /// yet available).
    ///
    /// The proof: drive `wireAll(router)` into a fresh router, then for every
    /// migrated group drive the group's own `wireGroup_<g>(router)` into a
    /// fresh router and assert the exact handler count. Deleting a `@Wired`
    /// annotation drops exactly one group's count, so this pin turns only one
    /// way. `wireAll` must register exactly 179: 164 generated + 1 typed action
    /// family (`StorageAction`) + 12 `nav-\(id)` + `sidebar-plugin-toggle` +
    /// `cat-pick`.
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
            #expect(router.handlerCount(in: .default) == 45, "chat group registration drifted")
        }

        @Test("every settings handler is registered after wireGroup_settings")
        func settingsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_settings(router)
            #expect(router.handlerCount(in: .default) == 25, "settings group registration drifted")
        }

        @Test("every settings_admin handler is registered after wireGroup_settings_admin")
        func settingsAdminGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_settings_admin(router)
            #expect(router.handlerCount(in: .default) == 30, "settings_admin group registration drifted")
        }

        @Test("every skills handler is registered after wireGroup_skills")
        func skillsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_skills(router)
            #expect(router.handlerCount(in: .default) == 15, "skills group registration drifted")
        }

        @Test("every profiles handler is registered after wireGroup_profiles")
        func profilesGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_profiles(router)
            #expect(router.handlerCount(in: .default) == 11, "profiles group registration drifted")
        }

        @Test("every mcp handler is registered after wireGroup_mcp")
        func mcpGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_mcp(router)
            #expect(router.handlerCount(in: .default) == 8, "mcp group registration drifted")
        }

        @Test("every chatmenu handler is registered after wireGroup_chatmenu")
        func chatmenuGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_chatmenu(router)
            #expect(router.handlerCount(in: .default) == 7, "chatmenu group registration drifted")
        }

        @Test("every workspaces handler is registered after wireGroup_workspaces")
        func workspacesGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_workspaces(router)
            #expect(router.handlerCount(in: .default) == 6, "workspaces group registration drifted")
        }

        @Test("every queue handler is registered after wireGroup_queue")
        func queueGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_queue(router)
            #expect(router.handlerCount(in: .default) == 6, "queue group registration drifted")
        }

        @Test("every tools handler is registered after wireGroup_tools")
        func toolsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_tools(router)
            #expect(router.handlerCount(in: .default) == 2, "tools group registration drifted")
        }

        @Test("every plugins handler is registered after wireGroup_plugins")
        func pluginsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_plugins(router)
            #expect(router.handlerCount(in: .default) == 2, "plugins group registration drifted")
        }

        @Test("every logs handler is registered after wireGroup_logs")
        func logsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_logs(router)
            #expect(router.handlerCount(in: .default) == 2, "logs group registration drifted")
        }

        @Test("every insights handler is registered after wireGroup_insights")
        func insightsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_insights(router)
            #expect(router.handlerCount(in: .default) == 1, "insights group registration drifted")
        }

        @Test("every toasts handler is registered after wireGroup_toasts")
        func toastsGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_toasts(router)
            #expect(router.handlerCount(in: .default) == 1, "toasts group registration drifted")
        }

        @Test("every todos handler is registered after wireGroup_todos")
        func todosGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_todos(router)
            #expect(router.handlerCount(in: .default) == 1, "todos group registration drifted")
        }

        @Test("every cron handler is registered after wireGroup_cron")
        func cronGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_cron(router)
            #expect(router.handlerCount(in: .default) == 1, "cron group registration drifted")
        }

        @Test("every regen handler is registered after wireGroup_regen")
        func regenGroupHasExactCount() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            controller.wireGroup_regen(router)
            #expect(router.handlerCount(in: .default) == 1, "regen group registration drifted")
        }

        @Test("wireAll registers exactly 179 handlers (164 generated + 1 action family + 12 nav ids + sidebar-plugin-toggle + cat-pick)")
        func wireAllRegistersExactly179() async throws {
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: Self.push)
            await controller.wireAll(router)

            let count = router.handlerCount(in: .default)
            #expect(
                count == 179,
                "wireAll must register exactly 179 handlers: 164 @Wired-generated + 1 typed action family + 12 nav-(id) + sidebar-plugin-toggle + cat-pick, got \(count)"
            )
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
        /// "Answers" is a push now, not a payload: the handler signals a structural
        /// change through the door and returns nothing for the server to write on
        /// the originating socket.
        @Test("the ratchet turns one direction: @Wired ids cannot be untyped")
        func ratchetTurnsOneDirection() async throws {
            let door = Door()
            let router = EventRouter()
            let controller = Controller(app: Self.app, push: door.push)
            await controller.wireAll(router)

            let outcome = await router.dispatch(
                EventData(component: ComponentID("chat-new"), event: "click", data: [:]))
            #expect(await door.batches == [[]],
                    "chat-new answers: it asks the door to look, and an empty batch is the nudge")
            #expect(outcome.fragments.isEmpty,
                    "the batch crossed the door, not the socket — the server has nothing to write")
        }
    }
}
