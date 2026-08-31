# ARC Agent

> **A**utomatic **R**eference **C**ounting — a nod to Swift's memory management model. Deterministic, predictable, efficient. The same philosophy applied to agent architecture.

ARC Agent is a **precompiled, Swift-native AI agent harness** — architecturally inspired by [Hermes Agent](https://hermes-agent.nousresearch.com), but built from the ground up for Swift's concurrency model, type system, and distribution story. Single binary, zero interpreter overhead, no npm dependency chain, instant startup.

**Status:** Vascular hardening. The core architecture is built across 80 source files with 171 passing tests and a clean release build. The project is now focused on hardening the internal data flow, session integrity, and error recovery before adding new capabilities. The web UI has a dual-mode asset pipeline — debug mode serves CSS/JS from disk for instant iteration, release mode compiles everything into the binary.

## Why Swift?

| Concern | Python Agent (Hermes) | Swift Agent (ARC) |
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

```
GatewayService (Service Lifecycle tree)
├── HTTPServerService (Hummingbird)
│   ├── GET /ui → HTMLDocument (Swift DSL → HTML)
│   ├── GET /ui/styles.css (debug mode only — reads from disk)
│   ├── GET /ui/scripts.js (debug mode only — reads from disk)
│   └── POST /v1/chat → SessionAgent
├── WebSocketServerService (NIOWebSocket, port+1)
├── TelegramAdapter (long polling)
├── MCPServerAdapter (MCP protocol)
├── SessionRegistry (actor)
│   └── SessionAgent [N] (Service per session)
│       └── ArcAgent (actor — prompt → LLM → tools → response)
└── DeliveryManager (actor — response routing)
```

**22 registered tools** across 7 toolsets: `core`, `file`, `terminal`, `web`, `delegation`, `kanban`, `profile`.

## Quick Start

```bash
# Build (debug mode — assets served from disk for live iteration)
swift build

# Run tests
swift test

# List tools
swift run arc-agent tools

# Chat (requires API key)
export ARC_API_KEY=sk-...
swift run arc-agent chat -q "hello world"

# Start gateway server (debug mode — edit CSS/JS, refresh browser)
swift run arc-agent serve --port 8080
```

## Two Build Modes

ARC Agent has two distinct build modes, each optimized for a different phase of the development lifecycle:

### 🛠️ Debug Mode (`swift build`)

**Purpose:** Rapid UI iteration. CSS and JavaScript are served from disk on every request.

```
Edit Assets/styles.css or Assets/scripts.js
        │
        ▼  (refresh browser)
   See changes instantly — no rebuild needed
```

- CSS is served at `/ui/styles.css` — edit and refresh
- JS is served at `/ui/scripts.js` — edit and refresh
- The HTML document links to these external URLs instead of inlining
- The `#if DEBUG` compiler flag enables the disk-reading routes automatically
- Run with `make dev` or `swift run arc-agent serve`

### 🚀 Release Mode (`swift build -c release`)

**Purpose:** Single-binary distribution. Everything is compiled into the executable.

```
make assets     → bake CSS/JS into generated Swift source
swift build -c release  → single binary with everything embedded
```

- CSS and JS are inlined as `<style>` and `<script>` tags
- The disk-reading routes do not exist in the release binary
- Zero runtime dependencies — one file, run anywhere
- Run with `make install` or `make update` (full cycle)

### Makefile

```bash
make          → debug build
make release  → optimized release build
make assets   → bake CSS/JS into generated Swift source
make install  → release + copy to ~/.local/bin
make update   → assets + release + install (full cycle)
make dev      → debug build + serve (assets from disk)
make test     → run all 117 tests
make dist     → create release tarball
make clean    → clean build artifacts
make uninstall → remove from install dir
```

### Asset Pipeline

```
Sources/ArcAgentCore/WebUI/Assets/
├── styles.css              ← Canonical CSS (edit here)
├── scripts.js              ← Canonical JS (edit here)
└── Generated/
    └── Assets.swift         ← Auto-generated by `make assets`
```

The canonical CSS and JS files live in `Assets/`. In debug mode, the HTTP server reads them from disk. Before a release build, run `make assets` to bake them into `Assets/Generated/Assets.swift` as static strings, which are then compiled into the binary.

## Roadmap

The project has completed five feature-build phases and is now in **vascular hardening**:

| Phase | Focus | Status |
|---|---|---|
| Phase A | Session & Data Integrity | 🔲 Not started |
| Phase B | Context & Memory | 🔲 Not started |
| Phase C | Error Handling & Recovery | 🔲 Not started |
| Phase D | Testing & Verification | 🔲 Not started |
| Phase E | Performance & Observability | 🔲 Not started |

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
| Asset pipeline | `make assets` — bakes CSS/JS into binary |

## Related

- [Hermes Agent](https://hermes-agent.nousresearch.com) — the Python agent framework that inspired this project's architecture
- [VISION.md](VISION.md) — full architecture document and hardening roadmap
- [AGENTS.md](AGENTS.md) — project phase and working conventions
- [docs/web-ui-architecture.md](docs/web-ui-architecture.md) — web UI subsystem architecture and dual-mode asset pipeline

## License

MIT
