// MARK: - SidebarTabHost

/// The host side-channel a tab can use to interoperate with arc agent
/// beyond pure HTML: toasts, navigation, workspace access, and refresh.
///
/// Implemented by the host; tabs receive it in
/// `SidebarTab.onActivate`/`onDeactivate` and may capture it in their
/// handlers. All calls are async and idempotent-friendly.
public protocol SidebarTabHost: Sendable {

    /// The workspace path of the active chat (or the active default
    /// workspace when no chat is open). Empty string when none.
    func workspacePath() async -> String

    /// Show a transient toast in the application chrome.
    func toast(_ message: String) async

    /// Switch the active view to another registered tab (any built-in
    /// or plugin tab id).
    func navigate(to tabID: String) async

    /// Ask the host to re-render the given tab's panel and main content
    /// (no-op for a tab that is not active).
    func refreshTab(_ tabID: String) async
}
