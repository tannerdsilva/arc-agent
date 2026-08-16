# ARC Agent

> **A**utomatic **R**eference **C**ounting — a nod to Swift's memory management model. Deterministic, predictable, efficient. The same philosophy applied to agent architecture.

ARC Agent is a **precompiled, Swift-native AI agent harness** — architecturally inspired by [Hermes Agent](https://hermes-agent.nousresearch.com), but built from the ground up for Swift's concurrency model, type system, and distribution story. Single binary, zero interpreter overhead, no npm dependency chain, instant startup.

**Status:** Vascular hardening. The core architecture is built across 51 source files with 75 passing tests. The project is now focused on hardening the internal data flow, session integrity, and error recovery before adding new capabilities.

## Why Swift?

| Concern | Python Agent (Hermes) | Swift Agent (ARC) |
|---|---|---|
| Startup time | ~500ms-2s | <50ms |
| Memory | ~150-300MB | ~20-50MB |
| Distribution | pip + venv + 227MB repo | Single binary (~20MB) |
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
├── TelegramAdapter (long polling)
├── MCPServerAdapter (MCP protocol)
├── SessionRegistry (actor)
│   └── SessionAgent [N] (Service per session)
│       └── ArcAgent (actor — prompt → LLM → tools → response)
└── DeliveryManager (actor — response routing)
```

**16 registered tools** across 6 toolsets: `file`, `terminal`, `web`, `core`, `delegation`, `kanban`.

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
| Storage | LMDB via CLMDB (raw C API) |
| Argument parsing | Swift Argument Parser |
| Lifecycle | Swift Service Lifecycle |
| Regex | Swift Regex (built-in) |

## Related

- [Hermes Agent](https://hermes-agent.nousresearch.com) — the Python agent framework that inspired this project's architecture
- [VISION.md](VISION.md) — full architecture document and hardening roadmap
- [AGENTS.md](AGENTS.md) — project phase and working conventions

## License

MIT
