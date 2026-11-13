import Testing
import WebUICore

// the premise that justified overlay.js's in-page `#` anchor interception,
// pinned in-process so the deletion that depends on it can never rot silently.
//
// the workaround claimed a `navigate` re-render "RESETS the render session —
// dropping every handler arc registered at boot … until the server is
// restarted". that was true of a plain `begin(_:)`, and false of the call the
// server actually makes: `WebUIServer.answerNavigate` re-renders with
// `router.begin(session, preservingRegistrations: true)` — landed in `a5fa7bb`
// (2026-10-14), an ancestor of this package's pinned revision. the interception
// was deleted on 2026-11-07 because of it.
//
// no-webui 2.8.0 removed the hazard at its root: a registration made without a
// session (`register(_:for:)`, arc's `Controller.wireAll`) no longer lands in
// `.default` at all — it lands in the router's HOST table, which no session
// reset can touch (§22.1/D1). both halves are still asserted, now at the level
// the pin is actually about: a plain `begin` must not drop a boot registration
// (the hazard stays gone), and the host table must answer a dispatch made in a
// session that never registered the id (the property `answerNavigate` relies
// on). a test that only checked the preserving path could not tell "the
// registration survived" from "the registration never landed".
extension ArcWebUITestRoot {

    @Suite("Anchor jump", .serialized)
    struct AnchorJumpTests {

        /// one distinguishable fragment, so `dispatch` proves the handler was
        /// REACHED and not merely present: the host table answers a session it
        /// does not belong to.
        private static let bootHandler: EventHandler = { _ in
            [FragmentUpdate(id: "boot-answered", html: "boot", transition: false)]
        }

        /// the shape `WebUIServer.init(router:eventRouter:…)` hosts use: a
        /// handler wired by hand, outside any render pass, landing in the
        /// router's host table.
        private static func bootWiredRouter() -> EventRouter {
            let router = EventRouter()
            router.register(Self.bootHandler, for: "boot-control")
            return router
        }

        @Test("a plain begin cannot drop the boot registration — the host table is not session state")
        func plainBeginKeepsBootRegistration() async {
            let router = Self.bootWiredRouter()
            // proves `register(_:for:)` reached the host table at all, so the
            // survival below is a fact and not an address that never held
            // anything. `.default` is a real render session now, and the boot
            // wiring is deliberately not in it.
            #expect(router.hostHandlerCount == 1)
            #expect(router.handlerCount(in: .default) == 0)

            router.begin(.default)

            #expect(
                router.hostHandlerCount == 1,
                "a plain begin dropped a boot registration — the in-page anchor workaround would be load-bearing again"
            )
            let outcome = await router.dispatch(
                EventData(component: "boot-control", event: "click", data: [:]), in: .default)
            #expect(outcome.fragments.count == 1, "the host table stopped answering a reset .default session")
        }

        @Test("the navigate re-render preserves the boot registration")
        func preservingBeginKeepsBootRegistration() async {
            let router = Self.bootWiredRouter()
            #expect(router.hostHandlerCount == 1)

            // exactly what `WebUIServer.answerNavigate` calls, and the reason
            // overlay.js no longer intercepts same-page `#` jumps.
            router.begin(.default, preservingRegistrations: true)

            #expect(
                router.hostHandlerCount == 1,
                "a navigate re-render dropped a boot registration — the in-page anchor workaround would be load-bearing again"
            )
            let outcome = await router.dispatch(
                EventData(component: "boot-control", event: "click", data: [:]), in: .default)
            #expect(outcome.fragments.count == 1, "the host table stopped answering the navigate's session")
        }
    }
}
