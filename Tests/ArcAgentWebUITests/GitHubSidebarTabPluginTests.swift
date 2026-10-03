import ArcSidebarTabs
import Foundation
import GitHubSidebarTab
import Testing

// MARK: - GitHubSidebarTab plugin package contract

@Suite("GitHub sidebar tab plugin")
struct GitHubSidebarTabPluginTests {

    @Test("plugin metadata is complete and describes exactly one tab")
    func pluginMetadata() {
        let plugin = GitHubSidebarTabPlugin()
        #expect(plugin.name == "github-sidebar-tab")
        #expect(!plugin.version.isEmpty)
        #expect(!plugin.description.isEmpty)
        let tabs = plugin.tabs()
        #expect(tabs.count == 1)
    }

    @Test("the tab conforms to SidebarTab with stable identity and icon")
    func tabIdentity() async throws {
        let plugin = GitHubSidebarTabPlugin()
        let tab = try #require(plugin.tabs().first)
        #expect(tab is any SidebarTab)
        #expect(tab.id == "github")
        #expect(SidebarTabID.isValid(tab.id))
        #expect(tab.title == "GitHub")
        #expect(tab.tooltip == "GitHub")
        #expect(tab.icon == SidebarTabIcon.named("git-branch"))
    }

    @Test("idle state renders panel and main content without touching git")
    func idleRender() async throws {
        let plugin = GitHubSidebarTabPlugin()
        let tab = try #require(plugin.tabs().first)
        guard let gh = tab as? GitHubSidebarTab else {
            Issue.record("tab is not GitHubSidebarTab")
            return
        }
        let panel = await gh.panelHTML()
        let main = await gh.mainHTML()
        #expect(panel.contains("Loading repository"))
        #expect(main.contains("Select a commit on the left"))
    }

    @Test("handler registrations are accepted (no-op host registration)")
    func installRegistersWires() async throws {
        let plugin = GitHubSidebarTabPlugin()
        let tab = try #require(plugin.tabs().first)
        var ids: [String] = []
        let registrar = CollectRegistrar { id, _, _ in ids.append(id) }
        await tab.install(SidebarTabRegistration(registrar))
        #expect(ids.contains("gh-refresh"))
        #expect(ids.contains("gh-commit"))
        #expect(ids.count == 2)
    }
}

/// Collects registered component ids for assertions.
private struct CollectRegistrar: SidebarTabRegistrar {
    let onRegister: @Sendable (String, Set<String>, @Sendable (SidebarTabEvent) async -> [SidebarFragment]) -> Void
    init(_ onRegister: @escaping @Sendable (String, Set<String>, @Sendable (SidebarTabEvent) async -> [SidebarFragment]) -> Void) {
        self.onRegister = onRegister
    }
    func register(
        id: String,
        events: Set<String>,
        handler: @escaping @Sendable (SidebarTabEvent) async -> [SidebarFragment]
    ) {
        onRegister(id, events, handler)
    }
}
