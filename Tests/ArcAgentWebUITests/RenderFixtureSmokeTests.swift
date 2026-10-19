import Testing
@testable import ArcWebUI
import WebUI

// the render fixture seam (AppState.RenderFixture): a deterministic state with
// no storage, no config reads and no background work. the production init
// resolves storage, reads ~/.arc-agent-webui/settings.json and ~/.arc/config.json,
// installs the AgentPowers gate and spawns an unstructured task; none of that
// belongs in a render test, and none of it is needed to draw a fragment.

extension ArcWebUITestRoot {

    @Suite("render fixture", .serialized)
    struct RenderFixtureSmokeTests {

        @Test("the fixture constructs and renders the topbar")
        func fixtureRendersTheTopbar() async {
            let app = AppState(renderFixture: .init())
            let html = await app.topbarHTML()
            #expect(html.contains("id=\"topbar\""))
        }

        @Test("the fixture leaves unused fields at their defaults")
        func fixtureDefaultsAreStable() async {
            let app = AppState(renderFixture: .init())
            #expect(await app.activeTabID == "chat")
            #expect(await app.settings.theme == "light")
            #expect(await app.sessions.isEmpty)
        }
    }
}
