import ArcToolKit
import Foundation
import Testing
@testable import ArcWebUI
import ArcAgentCore

// ===========================================================================
// MARK: - unbound chats inherit the default profile's context (H1)
//
// The Profiles editor save worked all along — the record and the disk overlay
// were both correct. The bug was in the resolution ladder: a chat with no
// binding in `settings.sessionProfile` (every "New chat") resolved no profile
// at all, so the default profile's `compressionBudget`/`contextLength`
// overrides were ignored and the engine fell back to the 32k default. The
// composer displayed "Profile — Default", so what the operator saw and what
// the engine did silently disagreed.
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("unbound chat profile context", .serialized)
    struct UnboundChatProfileContextTests {

        private static let defaultProfile = Profile(
            name: "default",
            title: "Default",
            context: ProfileContextConfig(
                contextLength: 599_040,
                compressionBudget: 130_048
            )
        )

        private static let customProfile = Profile(
            name: "lab",
            title: "Lab",
            context: ProfileContextConfig(compressionBudget: 8_192)
        )

        private func makeApp() -> AppState {
            AppState(renderFixture: AppState.RenderFixture(
                profiles: [Self.defaultProfile, Self.customProfile]
            ))
        }

        @Test("an unbound chat resolves the default profile's context overrides")
        func unboundInheritsDefault() async {
            let app = makeApp()
            let ctx = await app.profileContext(for: "fresh-session")
            #expect(ctx?.compressionBudget == 130_048)
            #expect(ctx?.contextLength == 599_040)
        }

        @Test("an unbound chat with no default profile on record resolves nothing")
        func unboundWithoutDefault() async {
            let app = AppState(renderFixture: AppState.RenderFixture(
                profiles: [Self.customProfile]
            ))
            let ctx = await app.profileContext(for: nil)
            #expect(ctx == nil)
        }

        @Test("a bound chat still resolves its own profile")
        func boundResolvesOwn() async {
            let app = AppState(renderFixture: AppState.RenderFixture(
                settings: { var s = AppSettings(); s.sessionProfile["sid-1"] = "lab"; return s }(),
                profiles: [Self.defaultProfile, Self.customProfile]
            ))
            let ctx = await app.profileContext(for: "sid-1")
            #expect(ctx?.compressionBudget == 8_192)
        }
    }
}
