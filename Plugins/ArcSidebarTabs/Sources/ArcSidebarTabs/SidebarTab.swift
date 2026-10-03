// MARK: - SidebarTab
//
// The contract for a sidebar tab in arc agent. A tab participates in the
// application's left rail (icon), the panel that shows next to the main
// page while the tab is active, and the main page itself.
//
// Requirements (must implement):
//   - `id`, `title`, `tooltip`, `icon`  — identity and rail presentation
//   - `panelHTML()` / `mainHTML()`      — panel and main page content
//
// Everything else is optional and provided as a default no-op:
//   - `install(_:)`   — register event handlers for interactive content
//   - `onActivate` / `onDeactivate`     — per-visit lifecycle
//
// A tab that needs to keep state (loaded data, selections, …) is free to
// be any Swift type — including an `actor` — since every protocol method
// is `async`. Tabs are value types held by the host; they must never
// trap or block: failures surface as ordinary states in the UI.
//
// MARK: - Where tabs live
//
// First-party tabs are provided by the arc-agent application itself
// through an adapter (see `BuiltInSidebarTabs` in ArcWebUI); their panel
// and main content still flow through this protocol.
//
// Third-party tabs come from a separate Swift package that depends on
// this kit and conforms to `SidebarTab` (and typically
// `SidebarTabPlugin` so the settings page can describe it). The package
// is added to the arc-agent build as a dependency and its tabs are passed
// to the application at startup. See `docs/sidebar-tab-plugins.md`.

/// A sidebar tab: rail icon, panel content, main page content, and
/// (optionally) event wiring and visit lifecycle.
///
/// Conformers are `Sendable` so the host can store and invoke them from
/// its own concurrent context. All rendering and lifecycle methods are
/// `async`; the host never blocks the main loop on a tab.
public protocol SidebarTab: Sendable {

    // MARK: Identity & rail presentation

    /// Unique, stable tab id. Lowercase slug
    /// (`SidebarTabID.isValid`): `[a-z0-9-]`, starts with a letter or
    /// digit, at most 48 characters. Must not collide with a built-in
    /// tab id. Handlers and the host resolve the tab by this id.
    var id: String { get }

    /// Display name (rail tooltip, settings chips, banners).
    var title: String { get }

    /// Short label for the hover tooltip pill next to the rail icon.
    var tooltip: String { get }

    /// Rail icon: a catalog symbol, custom SVG geometry, or an emoji.
    var icon: SidebarTabIcon { get }

    // MARK: Content

    /// The left panel shown while this tab is active. Plain HTML
    /// fragment; the host wraps it in the panel region.
    func panelHTML() async -> String

    /// The main page shown while this tab is active. Plain HTML
    /// fragment; the host wraps it in the main region.
    func mainHTML() async -> String

    // MARK: Interaction & lifecycle (defaulted)

    /// Register event handlers for this tab's content. Called once when
    /// the application starts; handlers stay registered forever.
    ///
    /// Handlers receive a ``SidebarTabEvent`` and return
    /// ``SidebarFragment``s describing which regions to update. They may
    /// also use the tab's own state and the ``SidebarTabHost`` side
    /// channel (toasts, navigation, …).
    func install(_ registration: SidebarTabRegistration) async

    /// Called whenever this tab becomes the active view (including the
    /// first open). Use for lazy loading, refresh-on-visit, or starting
    /// work the page needs.
    func onActivate(_ host: SidebarTabHost) async

    /// Called whenever this tab stops being the active view.
    func onDeactivate(_ host: SidebarTabHost) async
}

public extension SidebarTab {
    func install(_ registration: SidebarTabRegistration) async {}
    func onActivate(_ host: SidebarTabHost) async {}
    func onDeactivate(_ host: SidebarTabHost) async {}
}
