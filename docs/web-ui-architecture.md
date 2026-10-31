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
of `daemon.json` (on by default).

## dependency pin

`.package(url: "https://github.com/tannerdsilva/no-webui.git", branch: "master")`
— arc tracks no-webui's `master`, and `Package.resolved` records the revision
that resolves to (`ae911f44` when the pin moved). the identity is the repository
name `no-webui`, which is what every `.product(…, package: "no-webui")` keys on.

a branch pin moves: `swift package resolve` re-reads `master`, so the next build
compiles whatever landed there. `make check-pin` therefore proves resolution is
CURRENT rather than frozen — the resolved revision must equal the checkout's
HEAD — and `swift package resolve` is the fix when it does not.

this replaced the `path:` pin to `../pins/no-webui` on 2026-10-30.

## the co-development rule

arc and no-webui are co-developed on one disk, but arc builds against the
**pinned revision**, not `../no-webui`'s working tree; the sibling may
legitimately be ahead of the pin. before any arc commit that depends on
no-webui: `make check-pin` (non-zero means the manifest and `Package.resolved`
disagree — run `swift package resolve`). after any no-webui commit that touches
`WebUICore`, `WebUIDesignSystemCore`, `WebUIServer` or `WebUIState`: move the
pin, run `swift package resolve`, then `swift build --build-tests` in arc and
fix the consumer in the same session.

the failure mode this exists for is not a merge conflict — it is silence. when
no-webui's `@ElementBuilder` moved from erased arrays to a typed view tree, arc
reported **one** compile error, because each file masks the next: the bridge's
`HTMLEvent` frame hid `NewFeatures.swift`, which hid 41 sites in `Views.swift`,
which hid a second seam in `Actions.swift`. a build that stops at the first
error tells you nothing about the size of the drift. fix one error, rebuild,
and expect the count to rise before it falls.

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
├── MCPRules.swift         — Settings → MCP servers: form text → launch spec, validated
├── AppState+MCP.swift     — that panel's state: config write + live manager rebind
├── LogCollector.swift / Helpers.swift
└── Assets/                — host files the build plugins consume (never compiled):
                             `overlay.js` (the client overlay) plus `webui-assets.json`

(The theme catalog lives in `Sources/ArcTheme/`; the daemon lives in
`Sources/ArcDaemon/` — `DaemonPlan` resolves the surfaces, `ArcDaemon.run`
composes the tree.)

Note on MCP: the web UI turn loop dispatches tools straight through the
registry (no `ArcAgent`), so nothing in this process points the shared
`MCPClientManager` at `mcp_servers` unless the app does it — `AppState.init`
binds it at boot and every MCP config edit re-binds it. Without that, the
`mcp_tool` bridge is inert in the web UI however the config file reads. The
agent sees the bridge toggled by the `mcp` toolset in the Tools panel; the
Settings → MCP servers panel owns the launch spec (add/edit/delete/probe) and
writes the same `~/.arc/config.json` block the CLI (`arc mcp list`) reads.

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

## Event wiring

Handlers are **generated, not typed**. A controller type declares one
`@WireGroup(n)` per registration group, and the macro expands it into
`wireGroup_<n>(_ router:)` on that type; every `@Wired(id, events:)` handler the
group encloses becomes one `router.register` call in that function. `@Wired` is a
**peer marker — on its own it expands to nothing.** A `@Wired` handler in an
`extension Controller` that carries no `@WireGroup` therefore compiles cleanly and
is silently never registered; that failure shipped once and is fixed on this tree.
Registration is invisible in rendered bytes — no snapshot, parity digest or
browser smoke can see it — and `dispatch` returns `.fragments([])` both for "no
handler" and for "handler declined with a guard", so `EventRouter.handlerCount(in:)`
is the only honest observation. Never use a dispatch assertion as proof of
registration.

`Controller.wireAll` composes the generated groups with three hand-written
registrations that a `@Wired` marker cannot express — the only sanctioned literal
ids (documented in the `Controller.wire` doc comment):

- `nav-\(id)` in `wireNav` — the ids are not static literals; they come from
  `app.railTabIDs()` and are interpolated in a loop.
- `sidebar-plugin-toggle` in `wireSidebarPluginToggles` — one fixed id covers every
  third-party plugin row, and the handler dispatches on the event's `targetId`
  (`sbpl-<key>`).
- `cat-pick` in `wireChat` — it carries `contextmenu`, which is not an `HTMLEvent`
  case, so the macro cannot express its event set.

The census (measured 2026-10-22 on `htmlstring-eliminate` with a throwaway
diagnostic, `swift test --filter DiagTests`, since removed: a fresh `EventRouter`
per group, one `wireGroup_<g>` call, then `handlerCount`):

```
CHAT 45, SETTINGS 25, SETTINGS_ADMIN 30, SKILLS 15, PROFILES 11, MCP 8,
CHATMENU 7, WORKSPACES 6, QUEUE 6, TOOLS 2, PLUGINS 2, LOGS 2, INSIGHTS 1,
TOASTS 1, TODOS 1, CRON 1, REGEN 1                     = 164 in 17 groups
```

164 distinct ids, no duplicate. `wireAll` therefore registers **178 handlers**:
164 generated + 12 `nav-\(id)` + the 2 remaining escapes. The numbers are
measured, not derived — and the golden parity digest over
`Tests/ArcAgentWebUITests/Fixtures/parity` does not move when registration
changes, which is exactly why the invariant is counted rather than rendered.

## Streaming turns

A running turn renders into a dedicated live node, never by re-rendering the
transcript. Measured before this contract (2026-10-01, one chat, Max thinking):
the whole transcript was re-rendered on every push — 107–362 `#chat-inner`
teardowns per turn, 108–368 view transitions, and every `<details>` open state,
timestamp footer and hover node destroyed 2–8×/second.

The contract now:

- **Stable ids.** Every rendered unit is addressable: `msg-<rawIdx>` (assistant and
  tool messages), `turn-<turnIndex>` (completed turn blocks), and `live-turn` /
  `live-turn-body` / `live-turn-text` / `live-turn-thinking` (the running turn).
  User messages keep `msg-user-<idx>` — the conversation outline anchors on it.
- **Token pushes are text writes.** The streaming loop pushes
  `FragmentUpdate.text(id: "live-turn-text" | "live-turn-thinking")`; in steady state
  the engine mutates the text node's data, so the only mutations during a stream are
  characterData writes. The `live-turn` node replace is reserved for structural
  changes — status, tool chips, a row appearing or vanishing, the quantized TPS chip.
- **One derived push edge.** No handler assembles fragment html. A handler that
  changed state calls `Controller.changed()`, which pushes a `structuralChange()` nudge
  through `PushEdge`; the edge renders the shell once, diffs it against the baseline it
  holds with no-webui's `PageDiffer`, and broadcasts only the frames whose bytes moved.
  A turn boundary is therefore never a hand-picked list of regions: measured for a
  scripted turn, the start boundary shipped nine frames (`s-open-…`, `s-menu-…`,
  `chat-header`, `chat-scroll`, `chat-inner`, `composer-form`, `composer-input`,
  `cb-send`), the structural change then shipped `live-turn`, the tokens shipped two
  text writes, and the commit escalated to a single `#app` frame — bytes outside every
  region moved, so the differ escalated rather than shipping a partial patch.
  `#main` is never replaced on a turn boundary, because nothing names regions by hand
  any more.
- **A region's identity is the DOM `id`.** `RegionPolicy(identity: .elementID)`: a frame
  addresses an element the engine resolves with `getElementById`. Twenty elements carry
  `data-component-id` and no `id` at all — click-routing wrappers (panel bodies, picker
  grids, tab strips), never patch targets — and twelve pairs carry both attributes with
  different values, where the DOM id is what a patch must name. Both sets are pinned by
  `RegionIdentityCensusTests`, so a new one is a decision rather than an accident.
- **Two spans are excluded from the diff.** `live-turn-text` and `live-turn-thinking` are
  written only by `FragmentUpdate.text`; an html replace would reset the node the token
  writer owns, so the differ subtracts them from every ancestor's hash and never ships
  them.
- **Transitions are navigation-scale only.** Live fragments carry
  `transition: false`; `append`/`text` ops never animate. A full turn animates at its
  two boundaries at most.
- **In-process polish.** The live header shows an elapsed clock, and the tool status
  line names the running tool with its own client-ticked clock (`data-elapsed`, 1 s
  tick in `overlay.js`) — both stable spans the server never re-renders. Live
  reasoning renders in every activity mode except `hide_all_activity`.

The old machinery is gone: `PushDeduper`, `LiveTurnGate` and `PushPipeline` (71 lines
plus a 0.12 s timer) and the 149-site `refreshFragments()` fan-out. Each job is now
derived — an unchanged render produces no frames at all, so there is nothing to dedupe;
ordering is the door's own sequence (structure, then deltas), not a timer; and the
baseline lives in one `Mutex`-guarded differ per process, which is also why a push is a
single broadcast: every connected tab receives identical bytes.

After (same chat, measured live): a complete turn = ~63 characterData writes, 5
structural node swaps, 2 transcript renders, 2 transitions. Contract pins, all at the
wire: `PushDiffTests.swift` (the door — derived structure, verbatim deltas),
`StreamingDomContractTests.swift` (ids, ops, addressability),
`RegionIdentityCensusTests.swift`, `PushFanoutTests.swift`, `HostConfigTests.swift`. The
engine side is pinned by no-webui's browser smoke.

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

## why arc keeps its own components

the design system ships its own component set; arc keeps **10 hand-written
components** in `Sources/ArcWebUI/Components/` anyway. every one of them emits
arc's chrome classes, not framework classes: `akv`, `detail-card`,
`ctx-ring-svg`, `set-row`. the nearest framework component emits different
markup — `<dl class="list--desc">` for `WebUIDescriptionList`, `.card` for
`WebUICard`, a `progressbar` role for `WebUICircularProgress` — so replacing one
would change rendered bytes and orphan the 520 selectors of chrome sheet that
style them.

two of them additionally carry guarantees the framework cannot express:
`ArcButton` keeps `routing:` (the component id is not the element id, which is
how the wire dispatches on `targetId`) and `ArcSwitch` carries a `value:`
payload the change wires read. `WebUIButton` has no `routing:` and
`WebUIToggle` has no `value:`.

what was actually dead, measured rather than assumed: `DropdownRow`, `ListRow`
and `NamedListRow` had zero call sites outside their own file, and four
selectors had zero references. those were deleted. `SettingRow` was on that list
too and was **wrong** — it has 18 live call sites — which is why the deletion
order was "grep both, then delete". do not re-run this analysis and
"discover" a migration onto the framework components: it would silently drop
`data-component-id` routing on four sites.

## Known gaps

- **Open (2026-10-28): two push guards still read source text.**
  `UXHardeningContractTests` slices `turnChromeFragments()` out of `Actions.swift`, and
  `SettingsLayoutContractTests` slices `handleFontSizePick` — both then assert that
  `structuralChange()` / `changed()` appear in the body. They pass and they do guard the
  intent, but a rename that changes nothing would fail them, and they cannot see
  behaviour. Convert them to wire assertions (the shape `StreamingDomContractTests` now
  uses) when they next need touching.
- **Open (2026-10-28): concurrent structural pushes are not serialized.**
  `PushPipeline`'s submission chain went with it. `PageDiffer` makes each read-diff-write
  atomic, but two producers can interleave `render()`/`messages()` and put frames on the
  wire out of render order — a transient stale region that the next push corrects. An
  agent turn pushes structurally once at a time, so this is latent; a submission gate at
  the door is the fix if it ever bites.
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
product references. A second, hand-rolled UI surface (`WebSocketHandler.swift` /
`WebSocketServer.swift`) was removed in the same migration: it could never
render (no `onUI` closure was ever configured), so the socket server was
listening for pages that were never served.