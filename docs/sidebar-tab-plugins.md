# Sidebar Tab Plugins

Arc agent's sidebar tabs (Chat, Skills, Tools, …) are all expressed
through one protocol: `SidebarTab`, defined in the
[`ArcSidebarTabs`](../Plugins/ArcSidebarTabs) package. Third-party
packages implement the same protocol and are linked into the build as
additional libraries — the tab appears in the rail, the panel, and the
main page exactly like a built-in tab, and the Settings → Sidebar
plugins page lets the user hide/show it.

The reference implementation is the GitHub tab, extracted out of the
application into [`Plugins/GitHubSidebarTab`](../Plugins/GitHubSidebarTab).

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
  lifecycle hooks to interoperate with the application.

A tab may be any Swift type, including an `actor`; every protocol method
is `async`, and sync requirements (`id`, `title`, …) are `nonisolated`
on an actor. Tabs must not trap or block.

`SidebarTabPlugin` is the bundle descriptor the settings page shows:
`name`, `version`, `description`, and `tabs()`.

## Making a plugin package

A plugin is its own Swift package:

```
Plugins/MySidebarTab/
  Package.swift          # depends on ArcSidebarTabs (path or git)
  Sources/MySidebarTab/  # the tab + the plugin bundle
```

`Package.swift` dependencies (mirror the reference plugin):

```swift
.package(path: "../ArcSidebarTabs"),        // in-repo pin while co-developed
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

Component ids registered by a plugin are prefixed by the host, so plugin
ids never collide with built-ins or other plugins; ids only need to be
unique within the tab.

HTML helpers live in `SidebarTabHTML` (`escape`, `trunc`). The tab may
depend on `WebUI` (no-webui) for design-system icons and markup classes,
as the GitHub plugin does — plugin tabs run inside the application's
theme, and the `gh-*`/`panel-head` classes are the application's own
styles.

## Registering a plugin in the build

1. Add the package to the root `Package.swift`:
   ```swift
   .package(path: "Plugins/MySidebarTab"),
   ```
2. Add the product to the `ArcDaemon` target dependencies.
3. Pass a plugin instance where the daemon builds the UI host
   (`Sources/ArcDaemon/ArcDaemon.swift`):
   ```swift
   thirdPartyPlugins: [GitHubSidebarTabPlugin(), MyTabPlugin()]
   ```
4. `swift build` — the tab is registered at startup.

The application validates each tab at startup: an invalid `id`, a
collision with a built-in id, or a duplicate id drops the tab with a log
line instead of failing the boot. Newly registered tabs are visible in
the rail by default; Settings → Sidebar tabs chips reorder/hide them, and
Settings → Sidebar plugins shows one card per plugin with a show/hide
switch per tab.

## The GitHub tab as a worked example

- `Plugins/GitHubSidebarTab/` — package, models, git loader, the
  `GitHubSidebarTab` actor, and `GitHubSidebarTabPlugin`.
- Protocol features exercised: `.named("git-branch")` icon; async
  panel/main; `install` registrations (`gh-refresh`, `gh-commit`);
  `onActivate` lazy load from `host.workspacePath()`; `/usr/bin/git`
  subprocesses through SwiftSlash with a 20s bound; `SidebarTabHTML`
  escaping; no application imports — the tab only imports
  `ArcSidebarTabs`, `WebUI`, `SwiftSlash`, and Foundation.

## Design notes

- The protocol kit is dependency-free (Foundation + stdlib); the host
  adapts it to no-webui at the edge (`SidebarTabBridge` in ArcWebUI).
- Built-in tabs conform to the same protocol through thin adapters, so
  the entire shell (rail order, hidden set, dispatch, activation) is one
  mechanism.
- Tabs are pure UI+logic packages; the host owns persistence, chrome,
  and the render pipeline.
