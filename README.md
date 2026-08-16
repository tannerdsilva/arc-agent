# ARC Agent

> **A**utomatic **R**eference **C**ounting — a nod to Swift's memory management model. Deterministic, predictable, efficient. The same philosophy applied to agent architecture.

ARC Agent is a conceptual exploration of what a **precompiled, Swift-native AI agent harness** could look like. Inspired by the architecture of [Hermes Agent](https://hermes-agent.nousresearch.com), but built from the ground up for Swift's concurrency model, type system, and distribution story.

**This project is in its early stages.** We are working with concepts and prototypes, not production code. See [AGENTS.md](AGENTS.md) for the full context on where this project is and where it's going.

## Why Swift?

| Concern | Python Agent (Hermes) | Swift Agent (ARC) |
|---|---|---|
| Startup time | ~500ms-2s | <50ms |
| Memory | ~150-300MB | ~20-50MB |
| Distribution | pip + venv + 227MB repo | Single binary (~20MB) |
| Concurrency | threading + asyncio hybrid | Structured async/await + actors |
| Type safety | Runtime (duck typing) | Compile-time (strong typing) |
| Dependencies | 100+ Python + npm | 10-15 Swift packages |
| Tool schemas | Dicts at runtime | Codable + macros at compile time |

## Technical Requirements

All code in this project must satisfy two non-negotiable constraints:

1. **Swift Structured Concurrency.** Every concurrent operation uses `async`/`await`, actors, and task groups. No manually-created threads, no locks, no dispatch queues, no `@unchecked Sendable` annotations that bypass compiler enforcement.

2. **Swift Service Lifecycle.** Every long-lived component (agent loop, gateway, cron scheduler, kanban dispatcher) is a `Service` managed by `swift-service-lifecycle`. No ad-hoc daemon threads, no `atexit` handlers, no standalone `DispatchMain()` calls.

## Design Approach

The project follows a strict **protocols-first** design discipline:

1. **Protocol** — every abstraction starts as a protocol capturing the contract
2. **Concrete types** — structs and classes implement protocols; protocols never depend on concrete types
3. **Macros** — only after the protocol proves unwieldy in practice do we introduce macros to compress syntax

This ordering is load-bearing. Macros that paper over a bad protocol design hide the problem, not fix it.

## 1.0 Requirements

- **Native web UI** — a web-based user interface ships before 1.0. The approach is undecided and deferred (see VISION.md for options). The author will not write JavaScript, CSS, or HTML by hand.

## Architecture

The full architecture is documented in [VISION.md](VISION.md). At a high level:

```
Agent Loop (Actor)
  ├── Prompt Builder
  ├── LLM Call (OpenAI-compatible)
  ├── Tool Dispatch (Registry + Handler)
  │
  ├── Tool Registry (compile-time + plugins)
  ├── Provider Profiles (20+ providers)
  ├── Session Store (LMDB + QuickLMDB)
  ├── Delegation System (subagent spawning)
  ├── Kanban Board (multi-agent work queue)
  ├── Cron Scheduler (durable job store)
  ├── Security / Approval System
  ├── Memory Manager
  ├── Skills System
  └── Gateway (Hummingbird HTTP + platform adapters)
```

## Status

- **Phase:** Blue sky / conceptual exploration
- **Code:** None yet
- **Build:** None yet
- **Vision:** Documented in [VISION.md](VISION.md)

## Build Order (Planned)

1. **Core Agent** — tool registry, OpenAI-compatible client, agent loop, basic CLI
2. **Production Readiness** — providers, security, memory, skills, context compression
3. **Multi-Agent** — delegation, kanban, cron
4. **Gateway** — HTTP server, Telegram adapter, agent cache
5. **Polish** — plugins, MCP, distribution

## Technology Stack (Planned)

| Layer | Choice |
|---|---|
| Language | Swift 6+ |
| HTTP server | Hummingbird |
| HTTP client | AsyncHTTPClient |
| Storage | QuickLMDB (LMDB, v15) |
| YAML | Yams |
| Argument parsing | Swift Argument Parser |
| Lifecycle | Swift Service Lifecycle |
| Regex | Swift Regex (built-in) |

## Related

- [Hermes Agent](https://hermes-agent.nousresearch.com) — the Python agent framework that inspired this project's architecture
- [VISION.md](VISION.md) — full architecture document
- [AGENTS.md](AGENTS.md) — project phase and working conventions

## License

MIT
