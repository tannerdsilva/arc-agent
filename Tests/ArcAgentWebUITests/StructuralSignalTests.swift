import Testing
import WebUICore

@testable import ArcWebUI

// the stopgap seam (Task 2.1): a render-time control registers during a render
// pass, where the controller's push closure is not reachable. the app carries a
// signal the host installs beside the controller, so such a handler can still
// ask for the one structural re-render. the engine is expected to own this as a
// handler outcome, at which point the signal and its install disappear.
//
// two apps, one per test: `AppState` holds an `AsyncHTTPClient`, and building a
// fresh one per test trips its shutdown contract at suite teardown. the shared
// fixtures keep one client each for the suite's lifetime.
extension ArcWebUITestRoot {
    @Suite("Structural signal", .serialized)
    struct StructuralSignalTests {
        private actor Door {
            private(set) var count = 0
            nonisolated var signal: @Sendable () async -> Void {
                { [weak self] in await self?.bump() }
            }
            private func bump() { count += 1 }
        }

        private static let installed = AppState(renderFixture: .init())
        private static let bare = AppState(renderFixture: .init())

        @Test("every signalStructure call reaches the installed door once")
        func signalReachesDoor() async {
            let door = Door()
            await Self.installed.installStructuralSignal(door.signal)

            await Self.installed.signalStructure()
            await Self.installed.signalStructure()

            #expect(await door.count == 2,
                    "the door must see one nudge per call, not one per app lifetime")
        }

        @Test("a bare app has no door and signalStructure is a no-op")
        func bareAppIsSilent() async {
            // must not trap, await forever, or invent a door: a fixture renders
            // outside a host, and its render-time handlers mutate without a push.
            await Self.bare.signalStructure()
            #expect(Bool(true))
        }
    }
}
