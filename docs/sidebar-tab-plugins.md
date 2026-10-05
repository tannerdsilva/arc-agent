# Sidebar Tab Plugins

Arc agent's sidebar tabs (Chat, Skills, Tools, …) are all expressed
through one protocol: `SidebarTab`, defined in the
[`ArcSidebarTabs`](../Plugins/ArcSidebarTabs) package. Third-party
plugins implement the same protocol and run as **separate processes
(sidecars)**: the plugin is a small native executable the daemon spawns
at startup from `~/.arc/plugins/<name>/`. The tab appears in the rail,
the panel, and the main page exactly like a built-in tab, and the
Settings → Sidebar plugins page lets the user hide/show it. Installing a
plugin is a file copy — no rebuild, no access to the application source.

The reference implementation is the GitHub tab
([`Plugins/GitHubSidebarTab`](../Plugins/GitHubSidebarTab)).

## The protocol

`SidebarTab` (from `ArcSidebarTabs`) has four required members:

| Member | Purpose |
|---|---|
| `id` | Stable slug (`[a-z0-9-]`, ≤48 chars, no built-in collision). Rail button id is `nav-<id>`. |
| `title` / `tooltip` | Rail tooltip, settings chips, panel headings. |
| `icon` | `.named(catalog)` · `.custom(name:body:)` (sanitized SVG geometry) · `.emoji`. |
| `panelHTML()` / `mainHTML()` | Panel (left) and main page content when the tab is active. |

Everything else defaulted:

- `install(_ registration:)` — register event handlers. Handlers receive
  `SidebarTabEvent` (component id, event type, flat string values) and
  return `[SidebarFragment]`: `.panel(html)`, `.main(html)`, `.none`.
  The host maps these onto its own render regions, so a plugin never
  names a host region id or imports a web engine.
- `onActivate(_ host:)` / `onDeactivate(_ host:)` — per-visit lifecycle.
  The first activation is the natural place for lazy loading.
- `SidebarTabHost` — the side channel: `workspacePath()`, `toast(_:)`,
  `navigate(to:)`, `refreshTab(_:)`. Tabs call these from handlers and
  lifecycle hooks to interoperate with the application. In a sidecar
  these travel over the RPC channel and resolve against the live
  application state.

A tab may be any Swift type, including an `actor`; every protocol method
is `async`, and sync requirements (`id`, `title`, …) are `nonisolated`
on an actor. Tabs must not trap or block.

`SidebarTabPlugin` is the bundle descriptor the settings page shows:
`name`, `version`, `description`, and `tabs()`.

## Making a plugin package

A plugin is its own Swift package with **two products**: a library
containing the tabs, and an executable that hosts them over stdio:

```
Plugins/MySidebarTab/
  Package.swift
  Sources/MySidebarTab/      # the tab + the plugin bundle (library)
  Sources/MySidebarTabRunner/main.swift   # sidecar entry point
```

`Package.swift` dependencies (mirror the reference plugin):

```swift
.package(path: "../ArcSidebarTabs"),        // in-repo pin while co-developed
```

Products:

```swift
products: [
    .library(name: "MySidebarTab", targets: ["MySidebarTab"]),
    .executable(name: "my-sidebar-tab", targets: ["MySidebarTabRunner"]),
],
```

```swift
/// The tab.
public actor MyTab: SidebarTab {
    public nonisolated var id: String { "my-tab" }
    public nonisolated var title: String { "My Tab" }
    public nonisolated var tooltip: String { "My Tab" }
    public nonisolated var icon: SidebarTabIcon { .named("tool") }

    public func panelHTML() async -> String { … }
    public func mainHTML() async -> String { … }

    public func install(_ registration: SidebarTabRegistration) async {
        registration.on("my-refresh", events: ["click"]) { _ in
            await self.something()
            return [.panel(await self.panelHTML())]
        }
    }

    public func onActivate(_ host: SidebarTabHost) async {
        let path = await host.workspacePath()
        await self.load(path: path)
    }
}

/// The settings-card descriptor.
public struct MyTabPlugin: SidebarTabPlugin {
    public var name = "my-sidebar-tab"
    public var version = "1.0.0"
    public var description = "…"
    public init() {}
    public func tabs() -> [any SidebarTab] { [MyTab()] }
}
```

The sidecar entry point is one line — `SidecarServer` (from
`ArcSidebarTabs`) implements the RPC loop, tab descriptors, event
dispatch, and the `SidebarTabHost` proxy:

```swift
import ArcSidebarTabs
import MySidebarTab

try await SidecarServer.run(plugin: MyTabPlugin())
```

Component ids registered by a plugin are prefixed by the host, so plugin
ids never collide with built-ins or other plugins; ids only need to be
unique within the tab.

HTML helpers live in `SidebarTabHTML` (`escape`, `trunc`). The tab may
depend on `WebUI` (no-webui) for design-system icons and markup classes,
as the GitHub plugin does — plugin tabs render inside the application's
theme, and the `gh-*`/`panel-head` classes are the application's own
styles.

## Installing a plugin (shipped product)

1. Build the plugin package once by its author (or with
   `swift build --product my-sidebar-tab`).
2. Install its directory into the plugin root:
   ```
   ~/.arc/plugins/my-sidebar-tab/
     manifest.json          # { "name", "version", "description", "executable"? }
     my-sidebar-tab         # the compiled sidecar binary (chmod +x)
   ```
   `executable` defaults to the manifest `name`; the binary must be
   executable.
3. Start (or restart) the daemon. Discovery happens during boot: every
   directory with a valid manifest is spawned, handshaken via
   `listTabs`, and its tabs appear in the rail and the Settings → Sidebar
   plugins page. Invalid manifests, missing binaries, or failed
   handshakes are logged and skipped — a broken plugin never blocks the
   boot.

The daemon owns the plugin processes' lifecycle: `SidecarPluginService`
runs in the same `ServiceGroup` as the rest of the stack, and graceful
shutdown (SIGTERM) terminates every plugin child before the host exits —
no orphan processes. The host also keeps the plugin's stderr in the
daemon log (prefixed with the plugin name) for diagnosis.

## The wire protocol

Both ends share `SidecarProtocol.swift` in `ArcSidebarTabs`: a
JSON-lines envelope (`{id, method, params | result | error}`) on
`stdin`/`stdout`. Host→plugin methods: `listTabs`, `render`
(`{tab, region}`), `install`, `dispatchEvent` (`{tab, component, event,
values}`), `activate`, `deactivate`. Plugin→host requests: `host.workspacePath`,
`host.toast`, `host.navigate`, `host.refreshTab`. Correlated by `id`, so
requests and replies on either side never interleave. Nothing else is
touched: no ports, no sockets, no shared files.

## The GitHub tab as a worked example

- `Plugins/GitHubSidebarTab/` — package, models, git loader, the
  `GitHubSidebarTab` actor, `GitHubSidebarTabPlugin`, and the
  `GitHubSidebarTabRunner` executable hosting it as a sidecar.
- Distribution: build the runner, copy to
  `~/.arc/plugins/github-sidebar-tab/` with its `manifest.json`.
- Protocol features exercised: `.named("git-branch")` icon; async
  panel/main; `install` registrations (`gh-refresh`, `gh-commit`);
  `onActivate` lazy load from `host.workspacePath()`; `/usr/bin/git`
  subprocesses through SwiftSlash with a 20s bound; `SidebarTabHTML`
  escaping; the tab only imports `ArcSidebarTabs`, `WebUI`,
  `SwiftSlash`, and Foundation.

## Design notes

- The protocol kit is dependency-free (Foundation + stdlib); the host
  adapts it to no-webui at the edge (`SidebarTabBridge` + the sidecar
  client in ArcWebUI).
- Built-in tabs conform to the same protocol through thin adapters, so
  the entire shell (rail order, hidden set, dispatch, activation) is one
  mechanism.
- Sidecars keep the plugin sandboxed: a plugin crash takes down only its
  own process; the host reconnects nothing and the tab simply stops
  rendering (the tab's panel/main fall back to an "unavailable" hint).
- Plugins are pure UI+logic packages; the host owns persistence, chrome,
  the render pipeline, and process lifecycle.
