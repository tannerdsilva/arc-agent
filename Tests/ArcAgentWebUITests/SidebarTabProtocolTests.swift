import ArcSidebarTabs
import Foundation
import Testing
import WebUICore

@testable import ArcWebUI

// MARK: - SidebarTab protocol contract

/// A minimal conformer used to pin the REQUIRED surface of `SidebarTab`
/// (metadata + content) and the defaulted members (wiring/lifecycle).
private struct MockTab: SidebarTab {
    let id = "mock-tab"
    let title = "Mock"
    let tooltip = "Mock tab"
    let icon = SidebarTabIcon.named("tool")

    func panelHTML() async -> String { "<div>panel</div>" }
    func mainHTML() async -> String { "<div>main</div>" }

    /// Exercises the defaulted members: they must be callable from a
    /// conformer that only implements the required surface.
    func exerciseDefaults() async {
        var hits = 0
        let registrar = SpyRegistrar { _, _, _ in hits += 1 }
        let registration = SidebarTabRegistration(registrar)
        await install(registration)
        await onActivate(SpyHost())
        await onDeactivate(SpyHost())
        registration.on("x") { _ in [.none] }
        #expect(hits == 1)
    }
}

private struct SpyRegistrar: SidebarTabRegistrar {
    let onRegister: @Sendable (String, Set<String>, @Sendable (SidebarTabEvent) async -> [SidebarFragment]) -> Void
    func register(
        id: String,
        events: Set<String>,
        handler: @escaping @Sendable (SidebarTabEvent) async -> [SidebarFragment]
    ) {
        onRegister(id, events, handler)
    }
}

private struct SpyHost: SidebarTabHost {
    func workspacePath() async -> String { "" }
    func toast(_ message: String) async {}
    func navigate(to tabID: String) async {}
    func refreshTab(_ tabID: String) async {}
}

@Suite("Sidebar tab protocol")
struct SidebarTabProtocolTests {

    @Test("a minimal conformer satisfies the required surface and defaulted members")
    func minimalConformer() async {
        let tab = MockTab()
        #expect(tab.id == "mock-tab")
        #expect(tab.title == "Mock")
        #expect(tab.tooltip == "Mock tab")
        #expect(tab.icon == SidebarTabIcon.named("tool"))
        #expect(await tab.panelHTML() == "<div>panel</div>")
        #expect(await tab.mainHTML() == "<div>main</div>")
        // Defaulted install/activate/deactivate are no-ops but callable.
        var called = false
        let reg = SidebarTabRegistration(SpyRegistrar { _, _, _ in called = true })
        await tab.install(reg)
        #expect(!called)
        await tab.exerciseDefaults()
    }

    @Test("SidebarTabID shape validation")
    func idValidation() {
        #expect(SidebarTabID.isValid("github"))
        #expect(SidebarTabID.isValid("my-tab-1"))
        #expect(SidebarTabID.isValid("a"))
        #expect(SidebarTabID.isValid("123"))
        #expect(!SidebarTabID.isValid(""))
        #expect(!SidebarTabID.isValid("MyTab"))
        #expect(!SidebarTabID.isValid("my tab"))
        #expect(!SidebarTabID.isValid("my_tab"))
        #expect(!SidebarTabID.isValid("-lead"))
        #expect(!SidebarTabID.isValid("trail-"))
        #expect(!SidebarTabID.isValid("a--b"))
        #expect(!SidebarTabID.isValid(String(repeating: "a", count: 49)))
        #expect(SidebarTabID.isValid(String(repeating: "a", count: 48)))
    }

    @Test("SidebarTabEvent payload accessors")
    func eventAccessors() {
        let e = SidebarTabEvent(componentID: "x", event: "click", values: ["value": "hi", "checked": "true", "n": "3"])
        #expect(e.componentID == "x")
        #expect(e.event == "click")
        #expect(e.string("value") == "hi")
        #expect(e.bool("checked") == true)
        #expect(e.string("missing") == nil)
        #expect(e.bool("n") == nil)
    }

    @Test("SidebarTabHTML escaping and truncation")
    func htmlHelpers() {
        #expect(SidebarTabHTML.escape("<a href=\"x\">&'</a>") == "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;")
        #expect(SidebarTabHTML.trunc("hello", 5) == "hello")
        #expect(SidebarTabHTML.trunc("hello world", 8) == "hello w…")
        #expect(SidebarTabHTML.trunc("hi", 8) == "hi")
    }

    @Test("SidebarTabIcon values are equatable and sendable")
    func iconEquatable() {
        #expect(SidebarTabIcon.named("git-branch") == SidebarTabIcon.named("git-branch"))
        #expect(SidebarTabIcon.custom(name: "k", body: "<path/>") == SidebarTabIcon.custom(name: "k", body: "<path/>"))
        #expect(SidebarTabIcon.emoji("🔧") == SidebarTabIcon.emoji("🔧"))
        #expect(SidebarTabIcon.named("a") != SidebarTabIcon.emoji("a"))
    }
}

// MARK: - Host-side bridges

@Suite("Sidebar tab host bridge")
struct SidebarTabBridgeTests {

    @Test("fragment mapper plans regions in order and drops .none")
    func fragmentPlanning() {
        let plan = SidebarTabFragmentMapper.plan([
            .panel("<p>panel</p>"),
            .none,
            .main("<p>main</p>"),
        ])
        #expect(plan.count == 2)
        #expect(plan[0] == SidebarTabFragmentMapper.Plan(fragmentID: "panel", inner: "<p>panel</p>"))
        #expect(plan[1] == SidebarTabFragmentMapper.Plan(fragmentID: "main", inner: "<p>main</p>"))
        #expect(SidebarTabFragmentMapper.plan([.none]).isEmpty)
    }

    @Test("fragment updates are wrapped as the shell's region nodes")
    func fragmentWrapping() {
        let u = SidebarTabFragmentMapper.update(for: .init(fragmentID: "panel", inner: "<b>x</b>"))
        #expect(u.id == "panel")
        #expect(u.html == "<div id=\"panel\"><b>x</b></div>")
        let m = SidebarTabFragmentMapper.update(for: .init(fragmentID: "main", inner: "<i>y</i>"))
        #expect(m.id == "main")
        #expect(m.html == "<div id=\"main\"><i>y</i></div>")
    }

    @Test("registrar flattens scalar payload values and drops structured ones")
    func payloadFlattening() {
        var data: [String: JSONValue] = [
            "value": .string("hello"),
            "checked": .bool(true),
            "count": .number(3),
            "obj": .object([:]),
            "arr": .array([]),
            "nil": .null,
        ]
        let flat = AppSidebarTabRegistrar.flatten(data)
        #expect(flat["value"] == "hello")
        #expect(flat["checked"] == "true")
        #expect(flat["count"] == "3.0")
        #expect(flat["obj"] == nil)
        #expect(flat["arr"] == nil)
        #expect(flat["nil"] == nil)
        data.removeAll()
    }

    @Test("catalog symbol names resolve against the no-webui icon catalog")
    func catalogIconsResolve() {
        for name in ["git-branch", "message-square", "star", "settings", "chart-bar"] {
            #expect(IconName(rawValue: name) != nil, "missing catalog icon: \(name)")
        }
    }
}
