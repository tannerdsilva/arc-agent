# ARC Agent

> **A**utomatic **R**eference **C**ounting — a nod to Swift's memory management model. Deterministic, predictable, efficient. The same philosophy applied to agent architecture.

ARC Agent is a **precompiled, Swift-native AI agent harness** — architecturally inspired by [the reference agent](https://hermes-agent.nousresearch.com), but built from the ground up for Swift's concurrency model, type system, and distribution story. Single binary, zero interpreter overhead, no npm dependency chain, instant startup.

**Status:** Vascular hardening. The core architecture is built across 178 source files with 674 tests (2 of them environment-gated) and a clean build. The project is now focused on hardening the internal data flow, session integrity, and error recovery before adding new capabilities. The web UI ships as the `arc-agent-webui` executable: its CSS and JS are compiled into the binary as Swift — the theme sheet rendered, minified, stamped and gzipped from `Sources/ArcTheme/`, the client overlay embedded from `Assets/overlay.js` — and no-webui's `WebUIServer` serves them from content-stamped, immutable-cached urls.

## Why Swift?

| Concern | Python Agent (reference) | Swift Agent (ARC) |
|---|---|---|
| Startup time | ~500ms-2s | <50ms |
| Memory | ~150-300MB | ~20-50MB |
| Distribution | pip + venv + 227MB repo | Single binary (~33MB) |
| Concurrency | threading + asyncio hybrid | Structured async/await + actors |
| Type safety | Runtime (duck typing) | Compile-time (strong typing) |
| Dependencies | 100+ Python + npm | 11 Swift packages |
| Tool schemas | Dicts at runtime | Codable at compile time |

## The Law of the Land

All code in this project must satisfy two non-negotiable constraints:

1. **Swift Structured Concurrency.** Every concurrent operation uses `async`/`await`, actors, and task groups. No manually-created threads, no locks, no dispatch queues, no `@unchecked Sendable` annotations that bypass compiler enforcement.

2. **Swift Service Lifecycle.** Every long-lived component (agent loop, gateway, cron scheduler, kanban dispatcher) is a `Service` managed by `swift-service-lifecycle`. No ad-hoc daemon threads, no `atexit` handlers, no standalone `DispatchMain()` calls.

## Architecture

The full architecture is documented in [VISION.md](VISION.md). At a high level:

```text
GatewayService (Service Lifecycle tree)         — `arc serve`
├── HTTPServerService (Hummingbird)
│   ├── GET /health, POST /v1/chat → SessionAgent
│   └── GET /ui → "Web UI not configured" (the UI is served by arc-agent-webui)
├── WebSocketServerService (NIOWebSocket, port+1)
├── TelegramAdapter (long polling)
├── MCPServerAdapter (MCP protocol)
├── SessionRegistry (actor)
│   └── SessionAgent [N] (Service per session)
│       └── ArcAgent (actor — prompt → LLM → tools → response)
└── DeliveryManager (actor — response routing)

arc-agent-webui (executable)                     — web UI on :8890
├── AppState/Actions/Views/Theme  (Swift-generated HTML/CSS/JS, zero npm)
├── Entry.swift                   (page render, /ui/* host assets, ServiceGroup)
└── (client is no-webui's engine; the theme sheet is generated at build time)
```

**55 registered tools** across ~13 toolsets: `core`, `file`, `terminal`, `web`, `delegation`, `kanban`, `profile`, `media`, `webhooks`, `skills`, `mcp`, `project`, `tools`, `messaging` (arc-parity: `project_*`, unified `skill_manage` + `skills_list`, `tool_search`, `send_message`).

## Quick Start

```bash
# Build
swift build

# Run tests
swift test

# List tools
swift run arc-agent tools

# Chat (requires API key)
export ARC_API_KEY=sk-...
swift run arc-agent chat -q "hello world"

# Web UI (http://127.0.0.1:8890)
swift run arc-agent-webui

# Start the gateway (REST API + Telegram/Slack/Email adapters)
swift run arc-agent serve --port 8080
```

## Web UI

The web UI is a single Swift executable target, `Sources/ArcAgentWebUI/`, built on the declarative no-webui engine (Swift DSL → HTML/CSS/JS). There is no npm, no `package.json`, no node_modules, no build pipeline — every byte of CSS and JavaScript the UI needs is embedded in the binary:

- **Theme** — `Sources/ArcTheme/` holds the chrome stylesheet and the 27 schemes as no-webui
  providers (a shared base, token aliases, and a catalog the settings grid renders from); the
  served sheet is a **build product** — `ArcAssetTool theme-sheet` renders it, stamps its sha256
  into the url, and gzips it (271 kb → 30 kb on the wire)
- **no-webui's engine** — the client runtime. A page loads exactly two scripts: the
  engine (served by `WebUIServer` at `/ui/webui-engine.js`) and `init.js`, the
  arc-specific overlay, which rides the engine's `on.afterPatch` seam
- **Theme sheet** — rendered from `Sources/ArcTheme/` and emitted through no-webui's
  `WebUIBuild` by `ArcAssetPlugin` (via the `ArcAssetTool` target): minified, prose-gated,
  stamped and gzipped on every build
- **Client overlay** — `Sources/ArcAgentWebUI/Assets/overlay.js`, embedded by no-webui's
  `WebUIEmbedPlugin` from its `Assets/webui-assets.json` manifest on every build, so the
  served script is a build product too (gzipped, stamped, immutable)

Markdown in chat is rendered server-side by the arc-parity renderer in `Sources/ArcAgentCore/WebUI/Utilities.swift` (ATX headings, pipe tables, nested blockquotes, task checkboxes, sanitized images, autolinks) and enhanced client-side (table sort/filter).

### Makefile

```bash
make          → debug build
make release  → optimized release build
make install  → release + copy to ~/.local/bin
make update   → release + install (full cycle)
make dev      → debug build + web UI
make test     → run all tests
make dist     → create release tarball
make clean    → clean build artifacts
make uninstall → remove from install dir
```

## Roadmap

The project has completed five feature-build phases and is now in **vascular hardening**:

| Phase | Focus | Status |
|---|---|---|
| Phase A | Session & Data Integrity | ✅ Done |
| Phase B | Context & Memory | ✅ Done |
| Phase C | Error Handling & Recovery | ✅ Done |
| Phase D | Testing & Verification | ✅ Done |
| Phase E | Performance & Observability | 🔄 In progress |

See [VISION.md](VISION.md) for the full roadmap and subsystem documentation.

## Technology Stack

| Layer | Choice |
|---|---|
| Language | Swift 6.0 |
| HTTP server | Hummingbird 2.x |
| HTTP client | AsyncHTTPClient |
| Storage | Tessera via tessera-client (signed NOSTR events over WireGuard) |
| Argument parsing | Swift Argument Parser |
| Lifecycle | Swift Service Lifecycle |
| Regex | Swift Regex (built-in) |
| Web UI | Swift DSL → HTML/CSS/JS (zero npm) |
| WebSocket | NIOWebSocket (standalone, port+1) |
| Asset pipeline | Embedded Swift strings + a generated theme sheet |

## Related

- [the reference agent](https://hermes-agent.nousresearch.com) — the Python agent framework that inspired this project's architecture
- [VISION.md](VISION.md) — full architecture document and hardening roadmap
- [AGENTS.md](AGENTS.md) — project phase and working conventions
- [docs/web-ui-architecture.md](docs/web-ui-architecture.md) — web UI subsystem architecture and asset pipeline

## License

MIT
