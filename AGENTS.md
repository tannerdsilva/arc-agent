# ARC Agent — AGENTS.md

## Project Phase: Vascular Hardening

This project has completed five feature-build phases and is now in **vascular hardening** — strengthening the internal data flow, session integrity, error recovery, and observability before adding new capabilities.

The core architecture is built and proven:
- **63 Swift source files** across 12 subsystems
- **75 tests**, all passing
- **8 dependencies** (AsyncHTTPClient, ArgumentParser, System, ServiceLifecycle, QuickLMDB, CLMDB, Hummingbird, swift-mcp)
- **16 registered tools** across 6 toolsets
- **Full gateway stack** — HTTP server, Telegram adapter, MCP server, session management
- **LMDB-backed persistence** — per-session `.mdb` files with header/body split
- **Swift-native web UI** — declarative Swift DSL generating HTML/CSS/JS, served from the Hummingbird HTTP server at `GET /ui`. Zero npm, zero hand-written web code.

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
| Source files | 63 Swift files (51 core + 12 web UI) |
| Tests | 75, all passing |
| Build | Clean |
| Branch | `dev/all-phases` |

## Subsystem Inventory

| Subsystem | Files | Status |
|---|---|---|
| **Core Agent** — ArcAgent actor, prompt builder, turn loop | `Agent/ArcAgent.swift` | Built |
| **Tool Registry** — ToolEntry, JSONSchema, CompileTimeToolRegistry | `ToolRegistry/` (4 files) | Built |
| **Tools** — read_file, write_file, terminal, web_search, web_extract, delegation, kanban, memory, skill_view | `Tools/` (14 tools) | Built |
| **LLM Client** — LLMClient protocol, OpenAICompatibleClient, Message models | `LLM/` (3 files) | Built |
| **Provider System** — ProviderProfile, BundledProviders, CredentialPool | `Provider/` (3 files) | Built |
| **Session Management** — SessionStore protocol, LMDBSessionStore (header/body split) | `Session/` + `LMDB/` | Built |
| **Memory System** — MemoryProvider protocol, LMDBMemoryProvider, FileMemoryProvider | `Memory/` + `LMDB/` | Built |
| **Skills System** — Skill model, YAML frontmatter parsing, discovery | `Skills/Skill.swift` | Built |
| **Security** — ApprovalManager, dangerous command detection (Swift Regex) | `Security/ApprovalManager.swift` | Built |
| **Error Handling** — RetryHandler with exponential backoff + jitter | `ErrorHandling/RetryHandler.swift` | Built |
| **Config** — ArcConfig, JSON loading/saving, env var overrides | `Config/ArcConfig.swift` | Built |
| **Delegation** — DelegationManager, subagent spawning/steering/stopping | `Delegation/` (2 files) | Built |
| **Kanban** — KanbanBoard protocol, FileKanbanBoard, KanbanDispatcher, KanbanTask | `Kanban/` (4 files) | Built |
| **Cron** — CronScheduler, CronJob, schedule parsing | `Cron/` (2 files) | Built |
| **Gateway** — GatewayService, HTTPServerService, SessionRegistry, SessionAgent, TelegramAdapter, DeliveryManager, SessionRouter, PlatformAdapter | `Gateway/` (8 files) | Built |
| **MCP** — MCPServerAdapter, DynamicMCPTool | `Gateway/MCP/` (2 files) | Built |
| **LMDB** — LMDBWrapper (raw C API), LMDBManager, LMDBSessionStore, LMDBMemoryProvider | `LMDB/` (4 files) | Built |
| **Web UI** — View protocol, ViewBuilder, Primitives, Layouts, CSSRule, AppStyles, Scripts, HTMLDocument, ChatViews, Modifiers, ModifiedView, Utilities | `WebUI/` (12 files) | Built (uncommitted) |
| **Bot Mode** — Profile struct, ProfileManager, BotMessagingService, GroupChatRoom, BotViews, BotStyles, BotScripts, ProfileTools | `Profile/` (4 files) + `WebUI/` (3 files) + `Tools/` (1 file) | Built (uncommitted) |

## How We Work

1. **Vascular first.** Every change should improve the flow of information through the system — making it more reliable, observable, or resilient. If a change doesn't improve the vascular system, question whether it belongs in this phase.

2. **Test before hardening.** Write the test that proves the current behavior is wrong, then fix the code. Tests are the diagnostic monitors on the vascular system.

3. **One phase at a time.** Phase A (Session & Data Integrity) must be complete before Phase B begins. Each phase builds on the foundation of the previous one.

4. **Commit early, commit often.** Each hardening step is a separate commit with a clear before/after. The `dev/all-phases` branch is the active development branch.

5. **The Laws are not negotiable.** First Law (Structured Concurrency) and Second Law (Service Lifecycle) are enforced at every level. Code that violates them shall not be merged.

## The Law of the Land

HEAR YE, HEAR YE. In this beautiful project, of which we are so proud, there shall be a law of the land, of which all agents and humans alike shall abide unconditionally at all times. THE LAW OF THE LAND IS SIMPLE, AND AS FOLLOWS:

**First Law — Swift Structured Concurrency, Without Exception.** Every fiber of this codebase shall run on `async`/`await`, every mutable state shall be guarded by an `actor`, every concurrent work stream shall be expressed as a `TaskGroup` or `AsyncStream`. There shall be no threads spawned by hand. There shall be no locks acquired by hand. There shall be no dispatch queues, no semaphores, no `@unchecked Sendable` cheats that subvert the compiler's concurrency guarantees. The compiler is our shield, and we shall not set it aside.

**Second Law — Swift Service Lifecycle, Without Exception.** Every long-lived component — the agent loop, the gateway, the cron scheduler, the kanban dispatcher — shall be a `Service` in a tree managed by `swift-service-lifecycle`. There shall be no ad-hoc daemon threads, no `atexit` cleanup handlers, no `DispatchMain()` calls that bypass the lifecycle framework. Startup is ordered, shutdown is graceful, and every service knows its place in the hierarchy.

These two laws are not goals. They are not aspirations. They are **requirements**. Code that violates them shall not be merged. Agents that generate code violating them shall be corrected. Humans that accept code violating them shall be reminded.

This is the contract. This is the foundation. Everything else is negotiable.

## Web UI Law (Subsystem-Specific)

The web UI subsystem has an additional law:

**Second Law (Web UI) — No npm, No Exceptions.** There shall be no `npm install`, no `package.json`, no `node_modules`, no webpack, no vite, no tailwind, no react, no vue, no svelte, no solid, no alpine, no stimulus, no htmx, no turbolinks, no hotwire, no stimulus_reflex. There shall be no JavaScript written by hand in a separate file. There shall be no CSS written by hand. There shall be no HTML written by hand. Every byte the browser receives is compiled into the ARC Agent binary. This is not negotiable.

## Design Temperament

- **Protocols first, macros last.** Every abstraction starts as a protocol. Concrete types conform to protocols; protocols do not depend on concrete types. Only after evaluating what becomes unwieldy as a result of this discipline do we introduce macros to make syntax perfectly efficient.

- **Swift-idiomatic first.** If a pattern from Hermes Agent fights Swift's type system or concurrency model, find the Swift-native alternative — don't force the Python shape into Swift code.

- **Compile-time over runtime.** Prefer generics, protocols, and macros over dictionaries and dynamic dispatch. A compile-time error is better than a runtime crash.

- **Minimal dependencies.** Every Swift package we add is a maintenance commitment. Before adding a dependency, ask: "Can we do this with Foundation + Swift Standard Library in 200 lines?"

- **Single binary target.** The goal is a precompiled binary you can `brew install` and run. No interpreter, no virtual machine, no npm install.

- **Web UI is compiled, not served.** The web interface is a Swift DSL that generates HTML, CSS, and JS at compile time. The browser receives the output of Swift code — it never hosts a separate application.

## What Success Looks Like

Success for the hardening phase is:

- A gateway that survives concurrent sessions without resource leaks
- Session data that survives process crashes without corruption
- Token budgets that are accurate enough to prevent context overflows
- Error recovery that makes transient failures invisible to the user
- Test coverage on every critical path
- Streaming responses from the gateway and web UI
- Structured logging and metrics that make the system observable

If we achieve that, the project is ready for additional platform adapters, distribution tooling, and eventual public release.
