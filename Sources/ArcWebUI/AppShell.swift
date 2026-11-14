import WebUI
import WebUICore
import WebUIDesignSystem
import WebUIServer

/// The page template and the shipped assets: the shell every served page renders
/// through, and the two `WebUIAsset`s the server answers with.
public enum AppShell {

    /// The page region's id — `WebUIServer.pageRegionID`, spelled here because the
    /// framework keeps the constant internal and the id is the wire contract. The
    /// server patches this element when a re-render cannot be expressed as a
    /// region diff; without it, it reloads the document instead.
    static let pageRegionID = "webui-page"

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
    ///   publishes it once, as `RuntimeConfig.renderToken`: the engine echoes it on
    ///   every event and ping — so the server resolves each frame to the render
    ///   session it minted for this response (the session this page's render-time
    ///   `controlAttributes` handlers registered into) — and, since no-webui
    ///   2.11.0, it is the upload credential as well: the engine's upload
    ///   transport sends it as `X-Render-Token`, and the host validates it against
    ///   the same `UploadTokenStore` the page route records into. There is no
    ///   second token and no second meta. Everything the render did not wire still
    ///   answers from the router's host table (2.8.0: session first, host second —
    ///   §22.1/D1). nil/empty leaves the token out of the page — a page rendered
    ///   with no other runtime knob still carries the `{}` shape, byte for byte.
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
            // only a real token goes into the page: an empty one would say "a
            // token exists" to the client without ever validating.
            let token = (renderToken?.isEmpty == false) ? renderToken : nil
            // The token rides the runtime config, once.
            //
            // `RuntimeConfig.renderToken` makes the engine echo the token on
            // every event frame, and the server resolves such a frame to the
            // render session that token names (`WebUIServer.boundSession`)
            // instead of the `.default` session a tokenless page routes in.
            //
            // Before no-webui 2.8.0 that was fatal for a hand-wired host: arc
            // wires its controls ONCE at boot (`Controller.wireAll`), that boot
            // wiring landed in `.default`, and a token-bound frame dispatched
            // into a session that had never heard of the control's id — clicks,
            // sends, menus and the whole rail went dead with no error on either
            // side. 2.8.0 removed the trap by giving the router two scopes: the
            // `register(_:for:)` calls `wireAll` makes land in ONE sealed HOST
            // table, each render pass gets its own session (where
            // `controlAttributes` lands), and dispatch resolves the session
            // first and the host table second (§22.1/D1). So a token-bound frame
            // reaches the page's own render-time handlers, and every id the
            // render did not wire still answers from the host table: publishing
            // the token is what makes BOTH populations reachable from one page.
            //
            // 2.11.0's upload transport reads the same value
            // (`engine.config.renderToken`) and sends it as `X-Render-Token`, so
            // the page's one runtime knob is also its upload credential. The
            // separate upload meta this file used to emit is gone: two copies of
            // one credential could disagree, and the engine never read it.
            let runtime = RuntimeConfig(renderToken: token, maxFrameBytes: maxFrameBytes)
            // The page region, named by the server's own contract.
            //
            // A re-render the region differ cannot express — a first render, a
            // change outside every control, a region that appeared or vanished —
            // ships as this element's replacement (`WebUIServer.pageRegionID`,
            // a constant the framework keeps internal; the id is the wire
            // contract). Without it the server has nowhere to put those bytes
            // and honestly answers a full document load instead, which is what
            // every structural `@Wired` handler would turn into: a handler that
            // answers `.refresh` would reload the page (no-webui 2.12.0). With
            // it, the whole-page patch lands in place exactly as the producer
            // push's `#app` frame did.
            //
            // It wraps, it does not replace: `#app` keeps its id, its
            // `data-size` and its stylesheet rules, and the wrapper takes no
            // style of its own (`#app` is viewport-height, not parent-height).
            //
            // `data-webui-transition="off"` is the engine's page-level opt-out,
            // and it states the same policy this host already declares on every
            // diff it derives (`PushEdge.livePolicy.transition == false`: "the
            // diff is not a navigation and must not animate"). It is load
            // bearing for the whole-page patch: the server builds that frame
            // itself (`WebUIServer.diffFrame`) and does not stamp the policy's
            // transition flag on it, so without this the client wraps the patch
            // in `startViewTransition` and a viewport change mid-transition
            // throws `InvalidStateError: Transition was aborted…`.
            let page = Div(id: Self.pageRegionID) { Raw(body) }
                .data("webui-transition", "off")
                .markup
            return WebUI.HTMLDocument(
                title: "ARC Agent",
                body: page,
                rawStyles: [],
                // typed head: the overlay script is an `externalScript`, so the
                // document adds the render nonce itself and the url is escaped
                // like every other attribute — no markup string in this file.
                headContent: HeadContent {
                    .script(src: overlayURL)
                },
                htmlAttributes: themeAttrs,
                devMode: false,
                // Two runtime knobs, both facts about the socket that served
                // this page: the render token the engine echoes (so frames
                // resolve to this render's session) and the frame budget the
                // socket enforces. Either being absent drops only itself.
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