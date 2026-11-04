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
    ///   publishes it in the `arc-upload-token` meta and nowhere else, so the
    ///   upload route can tell a page this host served from one that never
    ///   loaded. It deliberately does NOT ride `RuntimeConfig.renderToken` (see
    ///   the note in the body).
    ///   nil/empty leaves the meta out of the page — a page rendered with no
    ///   other runtime knob still carries the `{}` shape, byte for byte.
    /// - parameter maxFrameBytes: the frame budget the server this page is served
    ///   from enforces (`WebUIServerConfig.maxFrameSize`), published so the engine
    ///   can refuse an over-budget frame before it closes the socket with 1009.
    ///   the caller reads it from the config the server is built with, never a
    ///   literal: a page that names a budget the socket does not enforce is worse
    ///   than a page that names none.
    public static func makeDocument(
        sheetURL: String,
        overlayURL: String,
        renderToken: String? = nil,
        maxFrameBytes: Int? = nil
    ) -> @Sendable (UnsafeMarkup, String) -> WebUI.HTMLDocument {
        { body, themeAttrs in
            // only a real token goes into the meta: an empty one would say "a
            // token exists" to the client without ever validating.
            let token = (renderToken?.isEmpty == false) ? renderToken : nil
            // The upload token rides ITS OWN meta, never `RuntimeConfig.renderToken`.
            //
            // `renderToken` in the runtime config makes the engine echo the token
            // on every event frame, and the server resolves such a frame to the
            // render session that token names (`WebUIServer.boundSession`) instead
            // of the `.default` session a hand-wired host registers into. arc wires
            // its controls ONCE at boot (`Controller.wireAll`) — the documented
            // shape for `init(router:eventRouter:…)` — so every token-bound frame
            // would be dispatched into a session that has never heard of the
            // control's id and answered with nothing at all: clicks, sends, menus
            // and the whole rail go dead with no error on either side. The token
            // exists for the upload route alone (it proves the page came from a
            // render this host served), so it is published where only that client
            // reads it.
            let runtime = RuntimeConfig(maxFrameBytes: maxFrameBytes)
            return WebUI.HTMLDocument(
                title: "ARC Agent",
                body: body,
                rawStyles: [],
                // typed head: the overlay script is an `externalScript`, so the
                // document adds the render nonce itself and the url is escaped
                // like every other attribute — no markup string in this file.
                headContent: HeadContent {
                    .script(src: overlayURL)
                    if let token { .meta(name: "arc-upload-token", content: token) }
                },
                htmlAttributes: themeAttrs,
                devMode: false,
                // The frame budget is the only runtime knob arc publishes: one
                // value named here, one value enforced by the socket that served
                // this page. (The upload token is a separate meta — see above.)
                runtimeConfig: runtime.isEmpty ? nil : runtime,
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