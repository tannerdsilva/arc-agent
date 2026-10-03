// MARK: - SidebarTabIcon

/// The rail icon of a sidebar tab.
///
/// Rendering is the host's job; the kit only models the three icon
/// sources. All of them are safe by construction:
///
/// - `.named` references the no-webui icon catalog by its kebab-case
///   symbol name (e.g. `"git-branch"`, `"message-square"`). The host
///   falls back to a generic placeholder when the symbol is unknown.
/// - `.custom` carries inner SVG geometry (path/line/circle/…) exactly
///   like no-webui's `WebUIIconCustom`; the host sanitizes it with the
///   allowlist before emission, so free-form geometry can never carry
///   scripts, event handlers, or URL references.
/// - `.emoji` renders the emoji glyph directly (scaled to the slot).
public enum SidebarTabIcon: Sendable, Equatable {
    /// Catalog symbol name. Example: `"git-branch"`.
    case named(String)

    /// Caller-supplied SVG geometry, sanitized by the host before
    /// emission. `name` must be identifier-safe (it is emitted as a
    /// `data-icon` attribute only).
    case custom(name: String, body: String)

    /// A single emoji glyph.
    case emoji(String)
}
