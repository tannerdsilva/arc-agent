import ArcSidebarTabs
import Foundation
import WebUI

// MARK: - Sidebar tab host bridge
//
// The application side of the `ArcSidebarTabs` kit: adapts the
// protocol surface onto `AppState` + the no-webui event router, so
// third-party tabs never need to know application internals.

// MARK: Host side channel

/// `SidebarTabHost` implementation backed by the application's state.
struct AppSidebarTabHost: SidebarTabHost {
    let state: AppState

    func workspacePath() async -> String {
        await state.activeWorkspacePath()
    }

    func toast(_ message: String) async {
        _ = await state.toast(message)
    }

    func navigate(to tabID: String) async {
        await state.switchTab(tabID)
        await state.notifyTabActivated(tabID)
        // Targeted: plugin tabs render inside #main via the tab protocol
        // adapter, so the rail + main updates carry the switch — no whole-app
        // swap (that reads as a page refresh).
        _ = await state.refreshFragments()
    }

    func refreshTab(_ tabID: String) async {
        guard await state.isActiveTab(tabID) else { return }
        _ = await state.refreshFragments()
    }
}

// MARK: Registration bridge

/// `SidebarTabRegistrar` implementation: translates kit registrations
/// into no-webui wire registrations and maps kit replies back onto
/// application fragments.
struct AppSidebarTabRegistrar: SidebarTabRegistrar {
    let router: EventRouter

    func register(
        id: String,
        events: Set<String>,
        handler: @escaping @Sendable (SidebarTabEvent) async -> [SidebarFragment]
    ) {
        router.register({ event in
            guard events.contains(event.event) else { return [] }
            let kitEvent = SidebarTabEvent(
                componentID: event.component.value,
                event: event.event,
                values: Self.flatten(event.data)
            )
            let fragments = await handler(kitEvent)
            return SidebarTabFragmentMapper.plan(fragments).map { SidebarTabFragmentMapper.update(for: $0) }
        }, for: ComponentID(id))
    }

    /// Flatten scalar payload values to strings; structured values
    /// (arrays/objects) are omitted.
    static func flatten(_ data: [String: JSONValue]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in data {
            switch value {
            case .string(let s): out[key] = s
            case .bool(let b): out[key] = b ? "true" : "false"
            case .number(let n): out[key] = String(n)
            default: continue
            }
        }
        return out
    }
}

// MARK: Fragment planning

/// The semantic → concrete region mapping for tab replies. Pure and
/// unit-testable: fragment plans are just `(region id, inner html)`.
enum SidebarTabFragmentMapper {

    struct Plan: Equatable {
        let fragmentID: String
        let inner: String
    }

    /// Map kit fragments onto the regions the application shell hosts.
    static func plan(_ fragments: [SidebarFragment]) -> [Plan] {
        fragments.compactMap { fragment in
            switch fragment {
            case .panel(let html): return Plan(fragmentID: "panel", inner: html)
            case .main(let html): return Plan(fragmentID: "main", inner: html)
            case .none: return nil
            }
        }
    }

    /// Wrap a plan into the shell's registered fragment update.
    /// The shell owns the region wrappers (`<div id="panel">…` /
    /// `<div id="main" class="…">…`), so the bridge reproduces them.
    static func update(for plan: Plan) -> FragmentUpdate {
        let html: String
        switch plan.fragmentID {
        case "panel":
            html = "<div id=\"panel\">\(plan.inner)</div>"
        case "main":
            html = "<div id=\"main\">\(plan.inner)</div>"
        default:
            html = plan.inner
        }
        return FragmentUpdate(id: plan.fragmentID, html: html)
    }
}

// MARK: AppState - sidebar tab registry

extension AppState {

    /// Resolve any tab (built-in or plugin) by id.
    func sidebarTab(_ id: String) -> (any SidebarTab)? {
        if let plugin = pluginTabs[id] { return plugin }
        if let kind = ViewID(rawValue: id) {
            return BuiltInSidebarTab(kind: kind, state: self)
        }
        return nil
    }

    /// The ids of all registered tabs, in settings order (built-ins +
    /// plugins interleaved as the user arranged them); unknown ids are
    /// dropped, and missing registered ids are appended so a newly
    /// installed tab is never unreachable.
    func sidebarTabIDs() -> [String] {
        var ids: [String] = []
        for id in settings.sidebarTabs where sidebarTab(id) != nil {
            if !ids.contains(id) { ids.append(id) }
        }
        for id in ViewID.allCases.map(\.rawValue) where !ids.contains(id) {
            ids.append(id)
        }
        for id in pluginTabs.keys.sorted() where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// The ids shown in the rail: the tab order minus hidden tabs, with
    /// Chat first and Settings pinned last.
    func railTabIDs() -> [String] {
        var ids = sidebarTabIDs().filter { !settings.hiddenSidebarTabs.contains($0) }
        ids.removeAll { $0 == "chat" || $0 == "settings" }
        return ["chat"] + ids + ["settings"]
    }

    func isActiveTab(_ id: String) -> Bool {
        activeTabID == id
    }

    /// The tab is a third-party plugin tab.
    func isPluginTab(_ id: String) -> Bool {
        pluginTabs[id] != nil
    }

    /// The active workspace path (active chat's workspace, else the
    /// active default workspace) — the path plugins inspect.
    func activeWorkspacePath() -> String {
        workspacePath(for: activeSessionID)
    }

    /// Activate a tab by id (any registered built-in or plugin tab).
    func switchTab(_ id: String) async {
        guard sidebarTab(id) != nil else { return }
        activeTabID = id
        createSkill = false
        skillEdit = false
        createProfile = false
        closeWorkspaceCreate()
        pendingDelete = false
        filePopOpen = false
        confirmDeleteID = nil
        if id == "tasks" {
            // the panel renders from the store-backed cache; refresh on open.
            await refreshScheduledJobs()
            if let sel = tasksSelectedID,
               let job = settings.scheduledJobs.first(where: { $0.id == sel }) {
                await ensureSessionMessages(jobSessionID(job))
            }
        }
    }

    /// Run the per-visit lifecycle hook for a tab (first open and every
    /// re-activation). The navigation wire calls this after switchTab.
    func notifyTabActivated(_ id: String) async {
        if let tab = sidebarTab(id) {
            await tab.onActivate(AppSidebarTabHost(state: self))
        }
    }

    /// Hide/show a plugin tab on the rail (persisted with the other
    /// sidebar visibility settings). Built-ins cannot be hidden except
    /// through the existing chips UI.
    func setSidebarPluginHidden(_ id: String, hidden: Bool) {
        guard pluginTabs[id] != nil else { return }
        var list = settings.hiddenSidebarTabs
        if hidden {
            if !list.contains(id) { list.append(id) }
            // Never strand the user on a tab they just hid.
            if activeTabID == id { activeTabID = "chat" }
        } else {
            list.removeAll { $0 == id }
            if !settings.sidebarTabs.contains(id) {
                settings.sidebarTabs.append(id)
            }
        }
        settings.hiddenSidebarTabs = list
        saveSettings()
    }
}

// MARK: Icon rendering

/// Render a `SidebarTabIcon` into the application's icon markup.
enum SidebarTabIconRenderer {
    /// Fallback glyph when a catalog name is unknown.
    static let fallback = WebUIIcon(.link, size: .large).render()

    static func render(_ icon: SidebarTabIcon, size: IconSize = .large) -> String {
        switch icon {
        case .named(let name):
            guard let raw = IconName(rawValue: name) else { return fallback }
            return WebUIIcon(raw, size: size).render()
        case .custom(let name, let body):
            return WebUIIconCustom(name: name, body: body, size: size).render()
        case .emoji(let glyph):
            return "<span class=\"rail-emoji\" role=\"img\" aria-hidden=\"true\">\(SidebarTabHTML.escape(glyph))</span>"
        }
    }
}
