import WebUI
import WebUICore
import WebUIDesignSystem
import WebUIServer

/// The page template and the shipped assets: the shell every served page renders
/// through, and the two `WebUIAsset`s the server answers with.
public enum AppShell {

    /// `data-scheme`/`data-theme` for `<html>`, escaped like every other attribute the
    /// framework emits.
    public static func themeAttrs(_ theme: (scheme: String, mode: String)) -> String {
        "data-scheme=\"\(esc(theme.scheme))\" data-theme=\"\(esc(theme.mode))\""
    }

    /// The page template: the framework's component sheet links FIRST, arc's own chrome +
    /// scheme sheet LAST.
    ///
    /// The body is an `UnsafeMarkup`, not a `String`: 2.0's document body carries the
    /// type, so a page cannot come from an unlabelled string. The body is built as a
    /// typed `View` tree (`Views.appShell()`), so this function never mints trust for
    /// arc's own chrome — the only trusted-markup seams left are the plugin panel ABI
    /// and sanitized markdown content.
    ///
    /// The head is `HeadContent`, not markup: `HTMLDocument` adds the render nonce to
    /// the overlay script and sanitizes its url, so this file carries no html at all.
    ///
    /// Two parameters, not one, and the order is the contract. `HTMLDocument` emits
    /// `stylesheetURL:` (the base sheet) before `themeStylesheetURL:`, and its `head:` slot —
    /// where arc's link used to live — renders *before* both. arc's markup leans on the
    /// framework's `.icon { width:1em }` base (15 of its rules size an svg's presentation
    /// only), so the component sheet must be linked; and arc's sheet must follow it, or the
    /// three colliding `:root` tokens (`--radius-sm/md/lg`) and ten like-named classes
    /// (`chip`, `kv`, `toast`, …) silently change ownership.
    /// - parameter renderToken: the token this response was rendered for. The page
    ///   echoes it in the `webui-config` meta so the upload route can tell a page
    ///   this host served from one that never loaded (`RuntimeConfig.renderToken`).
    ///   nil/empty leaves the meta at `{}` — the pre-upload shape, byte for byte.
    public static func makeDocument(
        sheetURL: String,
        overlayURL: String,
        renderToken: String? = nil
    ) -> @Sendable (UnsafeMarkup, String) -> WebUI.HTMLDocument {
        { body, themeAttrs in
            // only a real token goes into the meta: an empty one would say "a
            // token exists" to the client without ever validating.
            let token = (renderToken?.isEmpty == false) ? renderToken : nil
            return WebUI.HTMLDocument(
                title: "ARC Agent",
                body: body,
                rawStyles: [],
                // typed head: the overlay script is an `externalScript`, so the
                // document adds the render nonce itself and the url is escaped
                // like every other attribute — no markup string in this file.
                headContent: HeadContent { .script(src: overlayURL) },
                htmlAttributes: themeAttrs,
                devMode: false,
                // The token rides the framework's own runtime config, so the
                // client reads it from the same `webui-config` meta as every
                // other runtime knob and arc writes no client-side plumbing for it.
                runtimeConfig: token.map { RuntimeConfig(renderToken: $0) },
                // Extras, not a restated policy: a full policy names no nonce source, and
                // `HTMLDocument` then suppresses the pre-paint theme prelude rather than
                // emit an inline script the browser refuses (a stored scheme would flash
                // on every load). This directive is all arc needs beyond the framework
                // default — remote images in rendered markdown.
                contentSecurityPolicyExtras: "img-src 'self' data: https: blob:",
                // framework components (base sheet, emitted first)…
                stylesheetURL: DesignSystemAssets.stylesheetURL,
                // …then arc's chrome + 27 schemes, so its tokens win the collisions
                themeStylesheetURL: sheetURL
            )
        }
    }

    /// The shipped assets. One `WebUIAsset` owns the bytes, the url a page links and the
    /// registration the server answers with, so the address, the bytes and the cache policy
    /// cannot disagree — and a test pins the product against the source it came from.
    public enum Assets {

        /// The sheet is a build product (`ArcAssetTool theme-sheet`): rendered from
        /// `Sources/ArcTheme/`, stamped with the sha256 its url carries, and gzipped at build
        /// time.
        public static let sheet = WebUIAsset(ThemeSheetAssets.self, path: "/ui/style.css")

        /// The overlay is a shipped asset too: no-webui's embed plugin generates
        /// `EmbeddedAssets.swift` from `Assets/webui-assets.json` on every build, so the
        /// script's bytes, its address and its registration all come from one value as well.
        public static let overlay = WebUIAsset(ArcOverlay.self, path: "/ui/init.js")
    }
}