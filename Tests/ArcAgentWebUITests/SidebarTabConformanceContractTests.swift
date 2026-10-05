import Foundation
import Testing

@testable import ArcWebUI

/// Source-contract guards for the sidebar-tab protocol wiring. The
/// application shell must be registry-driven: built-ins and third-party
/// tabs flow through the same `SidebarTab` surface, and the GitHub tab
/// ships only as a plugin package.
@Suite("Sidebar tab conformance contracts")
struct SidebarTabConformanceContractTests {

    private func source(_ rel: String, inRoot rootPath: String = "Sources/ArcWebUI") -> String {
        (try? String(contentsOfFile: "\(rootPath)/\(rel)", encoding: .utf8)) ?? ""
    }

    @Test("every built-in view id is expressed through the tab registry")
    func builtInsFlowThroughRegistry() {
        let views = source("AppState.swift")
        // The iconbar + panel + main dispatch resolve tabs by id through
        // the registry, not through a ViewID switch.
        let shell = source("Views.swift")
        #expect(shell.contains("railTabIDs()"))
        #expect(shell.contains("sidebarTab(activeTabID)"))
        #expect(!shell.contains("switch activeView"))
        // The registry covers every built-in id through ViewID: the
        // bridge resolves built-in adapters via `ViewID(rawValue:)` and
        // orders them via `ViewID.allCases`.
        let adapters = source("BuiltInSidebarTabs.swift")
        #expect(adapters.contains("BuiltInSidebarTab"))
        let bridge = source("SidebarTabBridge.swift")
        #expect(bridge.contains("ViewID(rawValue: id)"))
        #expect(bridge.contains("ViewID.allCases"))
        #expect(views.contains("var symbolName"))
    }

    @Test("the GitHub tab is not part of the built-in binary")
    func githubIsNotBuiltIn() {
        let views = source("AppState.swift")
        #expect(!views.contains("case github"))
        #expect(!views.contains("defaultSidebarTabs = [\"skills\", \"profiles\", \"tools\", \"workspaces\", \"github\""))
        #expect(!source("Views.swift").contains("func githubPanel"))
        #expect(!source("Actions.swift").contains("wireGitHub"))
        #expect(!source("AppState.swift").contains("githubCommits"))
    }

    @Test("the daemon discovers sidecar plugins at startup")
    func daemonRegistersPlugin() {
        let daemon = source("ArcDaemon.swift", inRoot: "Sources/ArcDaemon")
        // Plugins ship as separate processes now (no compile-time package).
        #expect(!daemon.contains("import GitHubSidebarTab"))
        #expect(!daemon.contains("thirdPartyPlugins: [GitHubSidebarTabPlugin()]"))
        #expect(daemon.contains("sidecarManager.discover()"))
        #expect(daemon.contains("thirdPartyPlugins: sidecarPlugins"))
        #expect(daemon.contains("SidecarPluginService(manager: sidecarManager)"))
        // The host attaches its own app state to the manager at run() time.
        let host = source("WebUIHost.swift")
        #expect(host.contains("sidecarManager.attachHost"))
        #expect(host.contains("sidecarManager: SidecarPluginManager? = nil"))
    }

    @Test("plugin tab registrations are installed at wire time")
    func pluginsAreInstalled() {
        let actions = source("Actions.swift")
        #expect(actions.contains("installSidebarTabPlugins"))
        #expect(actions.contains("await tab.install(SidebarTabRegistration(registrar))"))
        #expect(actions.contains("app.pluginTabs"))
    }

    @Test("plugin toggles are wired and validated")
    func pluginTogglesWired() {
        let actions = source("Actions.swift")
        #expect(actions.contains("wireSidebarPluginToggles"))
        #expect(actions.contains("sbpl-"))
        let state = source("SidebarTabBridge.swift")
        #expect(state.contains("func setSidebarPluginHidden"))
    }

    @Test("settings exposes the third-party tab section")
    func settingsHasPluginSection() {
        let views = source("Views.swift")
        #expect(views.contains("id=\"sidebar-plugins\""))
        #expect(views.contains("func sidebarPluginsSettingsHTML"))
        #expect(views.contains("sidebarPluginsSettingsHTML()"))
        // Plugin chips join the built-in sidebar-tab chips.
        #expect(views.contains("for id in pluginTabs.keys.sorted()"))
    }
}
