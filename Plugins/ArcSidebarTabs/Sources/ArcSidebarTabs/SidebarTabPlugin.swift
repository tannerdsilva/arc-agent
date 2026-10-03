// MARK: - SidebarTabPlugin

/// The bundle descriptor of a third-party sidebar-tab package.
///
/// A plugin package exposes one instance (or several); the settings page
/// lists plugins and their tabs, and the user can hide/show individual
/// tabs. The host calls `tabs()` once at startup.
public protocol SidebarTabPlugin: Sendable {
    /// Package/short project name, e.g. `"github-sidebar-tab"`.
    var name: String { get }

    /// Semantic version of the plugin build.
    var version: String { get }

    /// One-line description shown in Settings → Sidebar plugins.
    var description: String { get }

    /// The tabs this plugin provides (at least one).
    func tabs() -> [any SidebarTab]
}
