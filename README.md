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
  ├── Session Store (GRDB + SQLite + FTS5)
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
| SQLite | GRDB.swift |
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
