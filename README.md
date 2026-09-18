# ARC Agent

> **A**utomatic **R**eference **C**ounting — a nod to Swift's memory management model. Deterministic, predictable, efficient. The same philosophy applied to agent architecture.

ARC Agent is a **precompiled, Swift-native AI agent harness** — architecturally inspired by [Hermes Agent](https://hermes-agent.nousresearch.com), but built from the ground up for Swift's concurrency model, type system, and distribution story. Single binary, zero interpreter overhead, no npm dependency chain, instant startup.

**Status:** Vascular hardening. The core architecture is built across ~80 source files with a clean build. The project is now focused on hardening the internal data flow, session integrity, and error recovery before adding new capabilities.

> **Frontend surface:** ARC Agent serves a **no-webui** browser frontend (chat, bots, settings) straight from the gateway — `arc serve` runs a raw-NIO host on `:8088` that renders every page through the [no-webui](https://github.com/tannerdsilva/no-webui) SwiftUI-for-web toolkit (design-system components, tokens, layout primitives — no hand-written HTML/CSS/JS). Interactive chat streams over a session-gated WebSocket. Login (WebUIAuth, argon2id) is on by default; the first-run password is printed and persisted hash-only. The REST API (`/health`, `/v1/chat`) remains on the Hummingbird server (`:8080`).

## Why Swift?

| Concern | Python Agent (Hermes) | Swift Agent (ARC) |
|---|---|---|
| Startup time | ~500ms-2s | <50ms |
| Memory | ~150-300MB | ~20-50MB |
| Distribution | pip + venv + 227MB repo | Single binary (~33MB) |
| Concurrency | threading + asyncio hybrid | Structured async/await + actors |
| Type safety | Runtime (duck typing) | Compile-time (strong typing) |
| Dependencies | 100+ Python + npm | 8 Swift packages |
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
│   ├── GET /health
│   └── POST /v1/chat → SessionAgent
├── WebUIService (raw NIO, no-webui)
│   ├── GET /                → chat page (WebSocket /ws for streaming)
│   ├── GET /bots            → bot roster + create form
│   ├── GET /settings        → config + cron view
│   ├── GET /login · /logout → WebUIAuth sessions (default on)
│   └── GET /__assets/…      → design-system css + js runtime
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
# Build
swift build

# Run tests
swift test

# List tools
swift run arc-agent tools

# Chat (requires API key)
export ARC_API_KEY=sk-...
swift run arc-agent chat -q "hello world"

# Start gateway server
swift run arc-agent serve --port 8080
```

### Makefile

```bash
make          → debug build
make release  → optimized release build
make install  → release + copy to ~/.local/bin
make test     → run tests
make dist     → create release tarball
make clean    → clean build artifacts
make uninstall → remove from install dir
```

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
| Frontend | SwiftUI (external app, embeds `ArcAgentCore` as a library) |

## Related

- [Hermes Agent](https://hermes-agent.nousresearch.com) — the Python agent framework that inspired this project's architecture
- [VISION.md](VISION.md) — full architecture document and hardening roadmap
- [AGENTS.md](AGENTS.md) — project phase and working conventions

## License

MIT
