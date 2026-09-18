# ARC Agent — AGENTS.md

## Project Phase: Vascular Hardening

This project has completed five feature-build phases and is now in **vascular hardening** — strengthening the internal data flow, session integrity, error recovery, and observability before adding new capabilities.

The core architecture is built and proven:
- **141 Swift source files** across 3 targets (ArcAgentCore library, arc-agent CLI, arc-agent-webui)
- **363 tests**, all passing across 29 suites
- **11 dependencies** (AsyncHTTPClient, ArgumentParser, System, ServiceLifecycle, tessera, Hummingbird, swift-mcp, swift-nio, swift-nio-extras, swift-http-types, no-webui)
- **40 registered tools** across ~9 toolsets
- **Gateway stack** — HTTP server, Telegram adapter, MCP server, session management
- **Tessera-backed persistence** — sessions and memory stored as signed NOSTR events through the tessera-client library
- **Swift-native web UI** — `arc-agent-webui` executable, declarative Swift DSL generating HTML/CSS/JS, served from its own Hummingbird server. Zero npm, zero hand-written web code. All assets (styles, runtime JS, KaTeX) are embedded Swift strings.

## What This Means for an AI Agent Reading This

You are working in a **functional codebase with a clear hardening roadmap**. The architecture is documented in VISION.md. The two Laws are enforced. Your job is to help harden the existing system — not to add features, but to make the existing pipes reliable, observable, and resilient.

When asked to produce code, assume it is:
- **Hardening-focused** — strengthening existing paths, not building new ones
- **Test-driven** — every change should be verified by tests
- **Observable** — add logging, metrics, or error classification alongside functional changes

## Current State

| What | Status |
|---|---|
| VISION.md | Updated with hardening roadmap + web UI architecture |
| AGENTS.md | This file |
| README.md | Updated |
| Source files | 141 Swift files (117 core + CLI, 14 webui, 9 core-WebUI shared) |
| Tests | 363, all passing (29 suites) |
| Build | Clean |
| Branch | `tessera` (active development; `dev/all-phases` remote has diverged) |

## Subsystem Inventory (highlights)

| Subsystem | Location | Status |
|---|---|---|
| **Core Agent** — ArcAgent actor, prompt builder, turn loop | `Agent/ArcAgent.swift` | Built |
| **Tool Registry** — ToolEntry, JSONSchema, CompileTimeToolRegistry | `ToolRegistry/` | Built |
| **Tools** — 40 tools (file, terminal, web, delegation, kanban, memory, skill_view, skill_creation, skill_edit, profile_edit, clarify, browser/CDP, media, webhooks, …) | `Tools/` | Built |
| **LLM Client** — LLMClient protocol, adapters (OpenAI, Anthropic, Gemini, Bedrock, Vertex, ACP, Codex) | `LLM/` | Built |
| **Provider System** — ProviderProfile, BundledProviders, CredentialPool | `Provider/` | Built |
| **Session Management** — SessionStore protocol, TesseraSessionStore | `Session/` + `Storage/` | Built |
| **Memory System** — MemoryProvider protocol, TesseraMemoryProvider, FileMemoryProvider | `Memory/` + `Storage/` | Built |
| **Skills System** — Skill model, YAML frontmatter parsing, discovery | `Skills/Skill.swift` | Built |
| **Security** — ApprovalManager, dangerous command detection, AgentPowers lockdown gate | `Security/` | Built |
| **Error Handling** — RetryHandler, CircuitBreaker, Failover, RecoveryState | `ErrorHandling/` | Built |
| **Delegation** — DelegationManager, subagent spawning/steering/stopping | `Delegation/` | Built |
| **Kanban** — KanbanBoard protocol, FileKanbanBoard, KanbanDispatcher | `Kanban/` | Built |
| **Cron** — CronScheduler, CronJob, schedule parsing | `Cron/` | Built |
| **Gateway** — GatewayService, HTTPServerService, SessionRegistry, SessionAgent, TelegramAdapter, DeliveryManager, SessionRouter, PlatformAdapter, ProfileRouting | `Gateway/` | Built |
| **MCP** — MCPServerAdapter, DynamicMCPTool | `Gateway/MCP/` | Built |
| **Tessera** — TesseraConnection (shared tunnel), TesseraSessionStore, TesseraMemoryProvider | `Storage/` | Built |
| **Web UI** — AppState, Actions, Views, Theme, RuntimeAsset, Queue, NewFeatures, Insights, Server, Entry | `Sources/ArcAgentWebUI/` | Built |
| **Shared renderers** — Hermes-parity markdownToHTML + MarkdownRenderer, WebSocket server/handler | `ArcAgentCore/WebUI/` (3 files) | Built |
| **Compression** — MicroCompactor (per-turn transcript absorption) | `Compression/` | Built |
| **Bot Mode** — Profile struct, ProfileManager, BotMessagingService, GroupChatRoom | `Profile/` | Built |

## How We Work

1. **Vascular first.** Every change should improve the flow of information through the system — making it more reliable, observable, or resilient. If a change doesn't improve the vascular system, question whether it belongs in this phase.

2. **Test before hardening.** Write the test that proves the current behavior is wrong, then fix the code. Tests are the diagnostic monitors on the vascular system.

3. **One phase at a time.** Phase A (Session & Data Integrity) must be complete before Phase B begins. Each phase builds on the foundation of the previous one.

4. **Commit early, commit often.** Each hardening step is a separate commit with a clear before/after. The `tessera` branch is the active development branch.

5. **The Laws are not negotiable.** First Law (Structured Concurrency) and Second Law (Service Lifecycle) are enforced at every level. Code that violates them shall not be merged.

## The Law of the Land

HEAR YE, HEAR YE. In this beautiful project, of which we are so proud, there shall be a law of the land, of which all agents and humans alike shall abide unconditionally at all times. THE LAW OF THE LAND IS SIMPLE, AND AS FOLLOWS:

**First Law — Swift Structured Concurrency, Without Exception.** Every fiber of this codebase shall run on `async`/`await`, every mutable state shall be guarded by an `actor`, every concurrent work stream shall be expressed as a `TaskGroup` or `AsyncStream`. There shall be no threads spawned by hand. There shall be no locks acquired by hand. There shall be no dispatch queues, no semaphores, no `@unchecked Sendable` cheats that subvert the compiler's concurrency guarantees. The compiler is our shield, and we shall not set it aside. (Known, accepted exceptions: Tessera/storage and CDP browser internals use a small number of `@unchecked Sendable`/lock workarounds documented in code.)

**Second Law — Swift Service Lifecycle, Without Exception.** Every long-lived component — the agent loop, the gateway, the cron scheduler, the kanban dispatcher — shall be a `Service` in a tree managed by `swift-service-lifecycle`. There shall be no ad-hoc daemon threads, no `atexit` cleanup handlers, no `DispatchMain()` calls that bypass the lifecycle framework. Startup is ordered, shutdown is graceful, and every service knows its place in the hierarchy.

These two laws are not goals. They are not aspirations. They are **requirements**. Code that violates them shall not be merged. Agents that generate code violating them shall be corrected. Humans that accept code violating them shall be reminded.

This is the contract. This is the foundation. Everything else is negotiable.

## Web UI Law (Subsystem-Specific)

**Second Law (Web UI) — No npm, No Exceptions.** There shall be no `npm install`, no `package.json`, no `node_modules`, no webpack, no vite, no tailwind, no react, no vue, no svelte, no solid, no alpine, no stimulus, no htmx, no turbolinks, no hotwire, no stimulus_reflex. There shall be no JavaScript framework, no CSS preprocessor, no build pipeline. The web UI is generated by Swift code in `Sources/ArcAgentWebUI/` — the CSS and JS it needs are Swift string constants:

- `Theme.swift` — the stylesheet (27 color schemes), pure Swift strings
- `RuntimeAsset.swift` — the client runtime JS, embedded strings
- `Generated/KaTeXAssets.swift` — KaTeX CSS/JS/fonts, regenerated by `python3 Scripts/gen_katex_assets.py` (`make assets`)

There is no "disk mode": every asset is compiled into the binary. Chat markdown is rendered server-side by the shared Hermes-parity renderer (`ArcAgentCore/WebUI/Utilities.swift`), then enhanced client-side (table sort/filter, KaTeX rendering).

## Design Temperament

- **Protocols first, macros last.** Every abstraction starts as a protocol. Concrete types conform to protocols; protocols do not depend on concrete types. Only after evaluating what becomes unwieldy as a result of this discipline do we introduce macros to make syntax perfectly efficient.

- **Swift-idiomatic first.** If a pattern from Hermes Agent fights Swift's type system or concurrency model, find the Swift-native alternative — don't force the Python shape into Swift code.

- **Compile-time over runtime.** Prefer generics, protocols, and macros over dictionaries and dynamic dispatch. A compile-time error is better than a runtime crash.

- **Minimal dependencies.** Every Swift package we add is a maintenance commitment. Before adding a dependency, ask: "Can we do this with Foundation + Swift Standard Library in 200 lines?"

- **Single binary target.** The goal is a precompiled binary you can `brew install` and run. No interpreter, no virtual machine, no npm install. The web UI is its own binary; the gateway is another; shared logic lives in ArcAgentCore.

## What Success Looks Like

Success for the hardening phase is:

- A gateway that survives concurrent sessions without resource leaks
- Session data that survives process crashes without corruption
- Token budgets that are accurate enough to prevent context overflows
- Error recovery that makes transient failures invisible to the user
- Test coverage on every critical path
- Streaming responses from the gateway and web UI
- Structured logging and metrics that make the system observable
- Locked-down surfaces (skills/profile edits) that cannot be bypassed

If we achieve that, the project is ready for additional platform adapters, distribution tooling, and eventual public release.
