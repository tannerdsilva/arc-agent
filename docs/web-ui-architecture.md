# Web UI Architecture

## Overview

The web UI is the `arc-agent-webui` executable target (`Sources/ArcAgentWebUI/`),
built on the declarative **no-webui** library (Swift DSL → HTML/CSS/JS). There is
no npm, no node_modules, no build pipeline: every asset required by the UI is
compiled into the binary as Swift strings.

Serving is no-webui's, not ours: `WebUIServer` (an actor) owns the HTTP page
route, the asset routes, and the `/ws` socket, and `WebUIServerService` hosts it
inside a `ServiceGroup`. `Entry.swift` no longer contains a server.

The gateway (`arc serve`) is a separate process and hosts **no** UI — it is the
REST API (`HTTPServerService`, Hummingbird: `/health`, `POST /v1/chat`) plus the
platform adapters. There is exactly one web UI, this one.

## Layout

```
Sources/ArcAgentWebUI/
├── Entry.swift            — CLI entrypoint, HTML shell, asset registration, CSP,
│                            ServiceGroup wiring (server + two streamers)
├── IntervalService.swift  — a poll loop as a Service (log stream, workspace tree)
├── AppState.swift         — actor: sessions, settings, registry, runTurn orchestration, fragments
├── Actions.swift          — wire handlers (settings, approvals, queues, skills, agent powers)
├── Views.swift            — all page/section HTML builders (chat, sidebar, settings, skills, …)
├── Theme.swift            — base stylesheet + 27 color schemes as Swift constants
├── RuntimeAsset.swift     — the client runtime JS, embedded as a Swift string
├── Queue.swift            — run-queue model/engine (sequential + parallel, output chaining)
├── NewFeatures.swift      — tabbed panels, todos, cron, regenerate
├── Insights.swift         — usage insights (top-10 skills, token/activity charts)
└── Assets/vendor/katex/   — vendored KaTeX source files (the generator's input)

Sources/ArcAssetTool/main.swift          — generates KaTeXAssets.swift from the vendor dir
Plugins/ArcAssetPlugin/plugin.swift      — runs the tool on every build
```

`KaTeXAssets.swift` is **not checked in**. `ArcAssetPlugin` regenerates it into
`.build/…/ArcAssetPlugin/` on every build from `Assets/vendor/katex/`, so the
embedded asset is a build product of its input and cannot drift from it.

## Rendering pipeline

1. **Server-side**: message content is rendered to HTML by the shared arc-parity
   renderer in `Sources/ArcAgentCore/WebUI/Utilities.swift`
   (`markdownToHTML` / `MarkdownRenderer`) — ATX headings, pipe tables, nested
   blockquotes, task checkboxes, KaTeX math elements, sanitized images, autolinks.
2. **Client-side enhancement**: table sort/filter, KaTeX rendering of
   `<equation-inline>`/`<equation-block>` elements, drag-and-drop, flyouts, and
   composer features (slash autocomplete, reply-with-selection context chips).
3. **Interaction**: a `WebUIServer` event (`data-component-id` + `data-event`)
   dispatches through no-webui's `EventRouter` into the `Controller` handlers,
   which return `[FragmentUpdate]`; the server writes them to the socket and the
   client runtime patches the DOM by element id. Unsolicited pushes (streaming
   turns, the live log ring buffer, the workspace tree) go out through
   `WebUIServer.broadcast`.

## Theming and icons

- `Theme.swift` holds 27 schemes. Each scheme's palette is emitted through
  no-webui's CSS builders (`CSSRule` / `CSSStylesheet` / `CSSMediaQuery`) into
  `#app[data-scheme=…][data-theme=…]` blocks that carry arc's own custom
  properties **and** the design tokens `ColorScheme.tokenMap` projects from the
  same values — so any no-webui component rendered inside `#app` inherits the
  active scheme. `ColorScheme.theme(isDark:)` exposes a scheme as a native
  `WebUITheme` for a `WebUIDocument`-rendered page.
- Icons are no-webui's: `WebUIIcon(_: IconName, size: IconSize)` over the
  generated 628-glyph catalog. There is no hand-drawn glyph table, and a wrong
  glyph is a compile error rather than a blank `<svg>`.
- no-webui products in use: `WebUI` (view DSL, `EventRouter`, `CSSRule`,
  `WebUIRuntime`, `WebUIIcon`), `WebUIDesignSystem` (`DesignToken`,
  `WebUITheme`), `WebUIServer`.

## Known gaps

- **`RuntimeAsset.swift` embeds a fork** of no-webui's client runtime
  (`designer/assets/webui-runtime.js`), ~59 KB against upstream's ~29 KB. The
  fork predates no-webui's render-token pings and its keyboard accessibility,
  and adds arc behaviour (scroll preservation, markdown-table enhancement, KaTeX
  post-render, slash/selection/queue extras). no-webui now exposes
  `WebUIRuntime.on.afterPatch/.ready` for exactly this — but see the journal:
  no-webui is engine-first (`webui-engine.js`), so the cutover should target the
  engine rather than the older runtime.
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