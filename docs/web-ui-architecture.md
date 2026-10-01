# Web UI Architecture

## Overview

The web UI is the `ArcWebUI` **library** target (`Sources/ArcWebUI/`), built on
the declarative **no-webui** library (Swift DSL → HTML/CSS/JS). There is no npm,
no node_modules, no build pipeline: every asset required by the UI is compiled
into the binary as Swift strings.

Serving is no-webui's, not ours: `WebUIServer` (an actor) owns the HTTP page
route, the asset routes, and the `/ws` socket; `WebUIServerService` hosts it
inside a `ServiceGroup`, and `WebUIHost.swift` owns the boot, the page template
wiring, and the two `IntervalService` streamers.

There is no standalone UI process any more: the daemon (`arc serve` →
`ArcDaemon`) mounts the host as a sibling of the REST API
(`HTTPServerService`, Hummingbird: `/health`, `POST /v1/chat`) and the platform
adapters — one `ServiceGroup` per process — so the UI shares the daemon's
storage pair, log sink and shutdown. The surface is gated by the `webui` block
of `gateway.json` (on by default).

## Layout

```
Sources/ArcWebUI/
├── WebUIHost.swift        — the host Service: boot, page provider, asset wiring,
│                            ServiceGroup (server + two streamers), shutdown bridge
├── AppShell.swift         — the page template + the two served `WebUIAsset`s
├── IntervalService.swift  — a poll loop as a Service (log stream, workspace tree)
├── WebUILogging.swift     — the idempotent swift-log → ring-buffer install
├── ScheduledJobsImport.swift — one-time lift of legacy settings jobs into the store
├── AppState.swift         — actor: sessions, settings, registry, runTurn orchestration, fragments
├── Actions.swift          — wire handlers (settings, approvals, queues, skills, agent powers)
├── Views.swift            — all page/section HTML builders (chat, sidebar, settings, skills, …)
├── Theme.swift            — arc's chrome stylesheet (layout, components, text-size axis)
├── Queue.swift            — run-queue model/engine (sequential + parallel, output chaining)
├── NewFeatures.swift      — tabbed panels, todos, scheduled tasks, regenerate
├── Insights.swift         — usage insights (top-10 skills, token/activity charts)
├── GitHub.swift / LogCollector.swift / Helpers.swift
└── Assets/                — host files the build plugins consume (never compiled):
                             `overlay.js` (the client overlay) plus `webui-assets.json`

(The theme catalog lives in `Sources/ArcTheme/`; the daemon lives in
`Sources/ArcDaemon/` — `DaemonPlan` resolves the surfaces, `ArcDaemon.run`
composes the tree.)

Tests/ArcAgentWebUITests/     — emission + catalog invariants for the web UI target (no coverage
                                until the scheme sheet shipped inert), plus the palette pins:
                                77 values over all 27 schemes guarding the minifier and emitter

Sources/ArcAssetTool/main.swift          — renders the theme sheet, emits it through `WebUIBuild`
Plugins/ArcAssetPlugin/plugin.swift      — runs the tool on every build
```

`ThemeSheetAssets.swift` is **not checked in**. `ArcAssetPlugin` regenerates it into
`.build/…/ArcAssetPlugin/` on every build from `Sources/ArcTheme/`, so the
embedded sheet is a build product of its input and cannot drift from it.

## The asset pipeline

SwiftPM allows exactly two mechanisms, so there are exactly two:

- **Rendered Swift** — `Sources/ArcTheme/` is arc's own and only arc can render it: a plugin
  cannot import a library, and no framework plugin can render a consumer's theme types. arc
  therefore keeps one small tool (`ArcAssetTool`, invoked by `ArcAssetPlugin` before every
  build) whose whole body is one call into the framework's `WebUIBuild`. It emits
  `ThemeSheetAssets.swift`: the sheet, minified, prose-gated, sha256-stamped and gzipped.
- **Files** — `Assets/webui-assets.json` declares the host files, and no-webui's
  `WebUIEmbedPlugin` embeds each one into `EmbeddedAssets.swift` on every build. The overlay
  is its one entry, with `prose` deliberately **off**: the framework has no javascript strip
  step, and a js comment stripper is a riskier tool than the css minifier — so the overlay's
  comments ship, by recorded decision rather than by default.

Both products feed `WebUIAsset`, which derives the url a page links and the registration the
server answers with from the same bytes — so an address and the bytes it names cannot
disagree, and the cache policy (`immutable`, one year) is part of the value rather than
something an entry has to remember to ask for.

## Rendering pipeline

1. **Server-side**: message content is rendered to HTML by the shared arc-parity
   renderer in `Sources/ArcAgentCore/WebUI/Utilities.swift`
   (`markdownToHTML` / `MarkdownRenderer`) — ATX headings, pipe tables, nested
   blockquotes, task checkboxes, sanitized images, autolinks (math renders as escaped
   literal text).
2. **Client-side enhancement**: table sort/filter, drag-and-drop, flyouts, and
   composer features (slash autocomplete, reply-with-selection context chips).
3. **Interaction**: a `WebUIServer` event (`data-component-id` + `data-event`)
   dispatches through no-webui's `EventRouter` into the `Controller` handlers,
   which return `[FragmentUpdate]`; the server writes them to the socket and the
   client runtime patches the DOM by element id. Unsolicited pushes (streaming
   turns, the live log ring buffer, the workspace tree) go out through
   `WebUIServer.broadcast`.

## Theming and icons

- `ThemeCatalog.swift` holds the 27 schemes as no-webui `WebUIThemeProvider`s.
  `ArcBaseTheme` carries the value each property takes in the *majority* of schemes plus the
  14 `TokenAlias` declarations, so a scheme states only what makes it that scheme and arc's
  own property names ride the framework's tokens (`--bg: var(--color-bg)`) instead of a
  hand-written mapping table — a mistyped token is a missing enum case. `ArcThemeCatalog` is
  the catalog: `entries` drives the settings grid (so the picker cannot list a scheme the
  sheet does not carry), and `stylesheet()` emits every scheme × mode scoped to
  `:root[data-scheme=…][data-theme=…]`, which is what lets the engine switch with no round
  trip. `--warning` stays literal on purpose: no-webui emits each alias into every block, and
  its token is not defined in every scheme, so the indirection would resolve to nothing where
  the property inherits the chrome sheet's orange today.
- Icons are no-webui's: `WebUIIcon(_: IconName, size: IconSize)` over the
  generated 628-glyph catalog. There is no hand-drawn glyph table, and a wrong
  glyph is a compile error rather than a blank `<svg>`.
- Host assets are **content-stamped and cached for a year**: the sheet and the
  overlay are linked as `…?v=<sha256 prefix>` derived from their own bytes, so a rebuild
  changes the url by construction and a repeat navigation transfers none of them. Both are
  served compressed (`Vary: Accept-Encoding`; gzip on request — 25,766 of 249,982 bytes for
  the sheet, 9,904 of 34,967 for the overlay) and `immutable`. The policy
  passes only its one extra (`img-src … https: blob:`) through
  `contentSecurityPolicyExtras`, so the framework's nonce — and with it the pre-paint theme
  prelude — survives.
- no-webui products in use: `WebUI` (view DSL, `EventRouter`, `CSSRule`,
  `WebUIRuntime`, `WebUIIcon`), `WebUIDesignSystem` (`DesignToken`, `WebUITheme`,
  `@Theme`, `TokenAlias`, `ThemeCatalog`), `WebUIServer`.

## Known gaps

- **Resolved (2026-09): the client runtime fork is gone.** `RuntimeAsset.swift`
  (a ~59 KB fork of no-webui's `webui-runtime.js`), its `Assets/runtime.js`
  source, and `gen_runtime.py` were deleted. `HTMLDocument` now boots no-webui's
  **engine**, and a page loads exactly two scripts: `/ui/webui-engine.js` (routed
  by `WebUIServer`) plus the arc overlay. Transport, event dispatch, fragment
  patching, scroll/form-state restore and sanitising are the engine's job.
  The overlay keeps only arc-specific behaviour — composer, markdown-table enhancement,
  slash menu, selection button, outline, worklog.
- **Resolved (2026-09): the overlay rides the engine's post-patch seam.** It used to rescan
  the whole document from a `MutationObserver` — including on its own edits, so a streaming
  turn re-triggered it repeatedly — and the seam the engine grew for exactly this
  (`WebUIEngine.on.afterPatch`, handing the patched subtree) sat unused. Enhancement is now
  scoped to the elements a fragment batch replaced. Registration happens on
  `DOMContentLoaded`: the overlay script precedes the engine's synchronous boot, so `ready`
  never fires for a hook registered after it, and the initial pass runs directly (every pass
  is idempotent).
- **Resolved (2026-09): the scheme sheet no longer ships inert.** `ThemePalette.customTokens`
  keys are css property names, so arc's bare dictionary keys emitted `bg: …` — a declaration
  the browser drops — and all 27 schemes painted the base sheet's palette while the served
  bytes looked plausible. The catalog emits `--bg` (or its alias), `Tests/ArcAgentWebUITests`
  pins the invariants, and the post-rewrite sheet is value-for-value identical to the
  pre-rewrite one (108 blocks; 0 changed / 0 lost / 0 added, aliases resolved).
- **Resolved (2026-09): the CSP keeps the pre-paint theme prelude.** arc restated the whole
  policy to add two directives, and a restated policy names no nonce source — so
  `HTMLDocument` suppressed the prelude rather than ship an inline script the browser refuses,
  and a stored scheme flashed on every load. It now declares two extras
  (`contentSecurityPolicyExtras`) and the render nonce survives.
- The panels still build their markup by hand (536 bespoke CSS classes across the
  target). They use no-webui's view DSL, icons and tokens, but not its component
  set — adopting `WebUIStat`/`WebUITable`/`WebUIEmptyState` etc. would re-skin the
  UI, not substitute into it.

## Shared renderers (ArcAgentCore/WebUI)

One file remains in `Sources/ArcAgentCore/WebUI/`:

- `Utilities.swift` — arc-parity `markdownToHTML`, `MarkdownRenderer`, `htmlEscape`, `sanitizeImageURL`

The original Swift-DSL view subsystem (View/ViewBuilder/HTMLDocument/CSSRule/…)
was removed in 2026-09 after the UI moved to no-webui — it had zero remaining
product references. The gateway's `WebSocketHandler.swift` / `WebSocketServer.swift`
were removed in the same migration: the gateway's second UI surface could never
render (`GatewayService` passed `onUI: nil`), so the socket server was listening
for pages that were never served.