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
// both halves are asserted on purpose. a test that only checked the preserving
// path cannot tell "the registration survived" from "the registration never
// landed", and either one would leave this pin green while the hazard it exists
// to rule out came back. half (a) is the witness that the reset really does
// drop a boot registration; half (b) is the property `answerNavigate` relies on.
extension ArcWebUITestRoot {

    @Suite("Anchor jump", .serialized)
    struct AnchorJumpTests {

        /// the registration is the subject, not the dispatch: the handler's
        /// answer is irrelevant, only its presence in the session's table.
        private static let noop: EventHandler = { _ in [] }

        /// the shape `WebUIServer.init(router:eventRouter:…)` hosts use: a
        /// handler wired by hand, outside any render pass, landing in the
        /// shared `.default` session.
        private static func bootWiredRouter() -> EventRouter {
            let router = EventRouter()
            router.register(Self.noop, for: "boot-control")
            return router
        }

        @Test("a plain begin drops the boot registration — the hazard the workaround feared was real")
        func plainBeginDropsBootRegistration() {
            let router = Self.bootWiredRouter()
            // proves `register(_:for:)` reached `.default` at all, so the drop
            // below is a reset and not an address that never held anything.
            #expect(router.handlerCount(in: .default) == 1)

            router.begin(.default)

            #expect(
                router.handlerCount(in: .default) == 0,
                "a non-preserving begin no longer resets the session — re-check the premise before trusting the anchor deletion"
            )
        }

        @Test("the navigate re-render preserves the boot registration")
        func preservingBeginKeepsBootRegistration() {
            let router = Self.bootWiredRouter()
            #expect(router.handlerCount(in: .default) == 1)

            // exactly what `WebUIServer.answerNavigate` calls, and the reason
            // overlay.js no longer intercepts same-page `#` jumps.
            router.begin(.default, preservingRegistrations: true)

            #expect(
                router.handlerCount(in: .default) == 1,
                "a navigate re-render dropped a boot registration — the in-page anchor workaround would be load-bearing again"
            )
        }
    }
}
