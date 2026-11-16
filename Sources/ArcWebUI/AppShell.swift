import WebUI
import WebUICore
import WebUIDesignSystem
import WebUIServer
import WebUIState

/// The page template and the shipped assets: the shell every served page renders
/// through, and the two `WebUIAsset`s the server answers with.
public enum AppShell {

    /// The policy every re-render of this page is diffed under.
    ///
    /// One value, one owner of the wire contract. `WebUIServerConfig.refreshPolicy`
    /// carries it, so the server's re-render — a `HandlerOutcome.refresh` and a
    /// producer refresh alike — decides which regions ship from the same rule the
    /// page was recorded under. A second policy anywhere would be a second diff
    /// regime over one page, and the two baselines would drift.
    ///
    /// - `identity: .elementID` is the only identity that is a real address: the
    ///   engine resolves a frame with `getElementById`, and the shell is full of
    ///   elements that carry a component attribute but no `id`.
    /// - `coverage: .finest` is what keeps a chrome change from dragging `#app`
    ///   onto the wire: a region ships only when its own bytes moved.
    /// - `escalation: .nearestTrackedAncestor` makes an appeared node a parent
    ///   replace instead of a whole page.
    /// - `excluded` names the two token-owned spans: `FragmentUpdate.text` writes
    ///   them on every streaming token, so their bytes must not make their
    ///   ancestors look changed — and must never ship as a replace, which would
    ///   re-mount the node and strand the token writer.
    /// - `transition: false` is a stated policy, not a `nil` delegation — a diff
    ///   is not a navigation and must not animate as one.
    static let refreshPolicy = RegionPolicy(
        identity: .elementID,
        coverage: .finest,
        escalation: .nearestTrackedAncestor,
        excluded: ["live-turn-text", "live-turn-thinking"],
        transition: false
    )

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
    /// The head is `HeadContent` — and since A17 it declares NOTHING: the client
    /// is no-webui's engine, which `HTMLDocument` emits itself, and arc ships no
    /// second script. `webui-assets.json` is empty for the same reason, and
    /// `ZeroClientScriptTests` is what keeps it that way: a `.js` anywhere under
    /// `Sources/` is a design regression, not a feature.
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
            // the framework's public constant — the id is the wire contract).
            // Without it the server has nowhere to put those bytes
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
            // and it states the same policy this host declares on every diff it
            // derives (`refreshPolicy.transition == false`: "the diff is not a
            // navigation and must not animate"). It is load
            // bearing for the whole-page patch: the server builds that frame
            // itself (`WebUIServer.diffFrame`) and does not stamp the policy's
            // transition flag on it, so without this the client wraps the patch
            // in `startViewTransition` and a viewport change mid-transition
            // throws `InvalidStateError: Transition was aborted…`.
            let page = Div(id: WebUIServer.pageRegionID) { Raw(body) }
                .data("webui-transition", "off")
                .markup
            return WebUI.HTMLDocument(
                title: "ARC Agent",
                body: page,
                rawStyles: [],
                // no `headContent`: the document declares no script of its own.
                // `HTMLDocument` emits the engine (`/ui/webui-engine.js` + its
                // `-ext` asset) and the render nonce is not needed for a document
                // that carries no inline script — A17 deleted the last one.
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
    ///
    /// ONE asset: the stylesheet. The client script was the other one until A17
    /// deleted it — the engine is the framework's, served by the framework's
    /// server, and arc contributes no second script.
    public enum Assets {

        /// The sheet is a build product (`ArcAssetTool theme-sheet`): rendered from
        /// `Sources/ArcTheme/`, stamped with the sha256 its url carries, and gzipped at build
        /// time.
        public static let sheet = WebUIAsset(ThemeSheetAssets.self, path: "/ui/style.css")
    }
}