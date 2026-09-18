# ARC Agent — AGENTS.md

## Project Phase: Vascular Hardening

This project has completed five feature-build phases and is now in **vascular hardening** — strengthening the internal data flow, session integrity, error recovery, and observability before adding new capabilities.

The core architecture is built and proven:
- **70 Swift source files** across 12 subsystems
- **11 dependencies** (AsyncHTTPClient, ArgumentParser, System, ServiceLifecycle, tessera, Hummingbird, swift-mcp, swift-nio, swift-nio-extras, swift-http-types)
- **22 registered tools** across 7 toolsets
- **Full gateway stack** — HTTP server, Telegram adapter, MCP server, session management
- **Tessera-backed persistence** — sessions and memory stored as signed NOSTR events through the tessera-client library
- **SwiftUI frontend surface** — the user interface is a SwiftUI app that lives *outside* this package and embeds `ArcAgentCore` as a library, in-process. A SwiftUI-style view DSL is preserved — commented out — under `Sources/ArcAgentCore/UI/` as reference for that work. There is no web UI, no HTML/CSS/JS, no WebSocket, and no `/ui` routes in this project.

> **Note on build state:** the in-repo web-UI serving stack was removed in one pass, and the project is intentionally left in a **non-building state** until the external SwiftUI frontend work lands. Do not treat the red build as a regression; treat it as the frontend surface being absent.

## What This Means for an AI Agent Reading This

You are working in a **functional codebase with a clear hardening roadmap**. The architecture is documented in VISION.md. The two Laws are enforced. Your job is to help harden the existing system — not to add features, but to make the existing pipes reliable, observable, and resilient.

When asked to produce code, assume it is:
- **Hardening-focused** — strengthening existing paths, not building new ones
- **Test-driven** — every change should be verified by tests
- **Observable** — add logging, metrics, or error classification alongside functional changes

## Current State

| What | Status |
|---|---|
| VISION.md | Updated with hardening roadmap |
| AGENTS.md | This file |
| README.md | Updated |
| Source files | 70 Swift files (69 in ArcAgentCore + CLI main) |
| Tests | 123, web-UI tests removed with the surface |
| Build | Non-building by design (frontend surface removed; see note above) |
| Branch | `tessera` |

## Subsystem Inventory

| Subsystem | Files | Status |
|---|---|---|
| **Core Agent** — ArcAgent actor, prompt builder, turn loop | `Agent/ArcAgent.swift` | Built |
| **Tool Registry** — ToolEntry, JSONSchema, CompileTimeToolRegistry | `ToolRegistry/` (4 files) | Built |
| **Tools** — read_file, write_file, terminal, web_search, web_extract, delegation, kanban, memory, skill_view | `Tools/` (14 tools) | Built |
| **LLM Client** — LLMClient protocol, OpenAICompatibleClient, Message models | `LLM/` (3 files) | Built |
| **Provider System** — ProviderProfile, BundledProviders, CredentialPool | `Provider/` (3 files) | Built |
| **Session Management** — SessionStore protocol, TesseraSessionStore | `Session/` + `Storage/` | Built |
| **Memory System** — MemoryProvider protocol, TesseraMemoryProvider, FileMemoryProvider | `Memory/` + `Storage/` | Built |
| **Skills System** — Skill model, YAML frontmatter parsing, discovery | `Skills/Skill.swift` | Built |
| **Security** — ApprovalManager, dangerous command detection (Swift Regex) | `Security/ApprovalManager.swift` | Built |
| **Error Handling** — RetryHandler with exponential backoff + jitter | `ErrorHandling/RetryHandler.swift` | Built |
| **Config** — ArcConfig, JSON loading/saving, env var overrides | `Config/ArcConfig.swift` | Built |
| **Delegation** — DelegationManager, subagent spawning/steering/stopping | `Delegation/` (2 files) | Built |
| **Kanban** — KanbanBoard protocol, FileKanbanBoard, KanbanDispatcher, KanbanTask | `Kanban/` (4 files) | Built |
| **Cron** — CronScheduler, CronJob, schedule parsing | `Cron/` (2 files) | Built |
| **Gateway** — GatewayService, HTTPServerService, SessionRegistry, SessionAgent, TelegramAdapter, DeliveryManager, SessionRouter, PlatformAdapter | `Gateway/` (8 files) | Built (no web UI serving) |
| **MCP** — MCPServerAdapter, DynamicMCPTool | `Gateway/MCP/` (2 files) | Built |
| **Tessera** — TesseraConnection (shared tunnel), TesseraSessionStore, TesseraMemoryProvider, TesseraConfig | `Storage/` (4 files) | Built |
| **UI Surface** — SwiftUI-style view DSL, preserved commented out | `UI/` (9 files, fully commented) | Preserved (inert) |
| **Bot Mode** — Profile struct, ProfileManager, BotMessagingService, GroupChatRoom, ProfileTools | `Profile/` (4 files) + `Tools/` (1 file) | Built |

## How We Work

1. **Vascular first.** Every change should improve the flow of information through the system — making it more reliable, observable, or resilient. If a change doesn't improve the vascular system, question whether it belongs in this phase.

2. **Test before hardening.** Write the test that proves the current behavior is wrong, then fix the code. Tests are the diagnostic monitors on the vascular system.

3. **One phase at a time.** Phase A (Session & Data Integrity) must be complete before Phase B begins. Each phase builds on the foundation of the previous one.

4. **Commit early, commit often.** Each hardening step is a separate commit with a clear before/after. The active development branch is `tessera`.

5. **The Laws are not negotiable.** First Law (Structured Concurrency) and Second Law (Service Lifecycle) are enforced at every level. Code that violates them shall not be merged.

## The Law of the Land

HEAR YE, HEAR YE. In this beautiful project, of which we are so proud, there shall be a law of the land, of which all agents and humans alike shall abide unconditionally at all times. THE LAW OF THE LAND IS SIMPLE, AND AS FOLLOWS:

**First Law — Swift Structured Concurrency, Without Exception.** Every fiber of this codebase shall run on `async`/`await`, every mutable state shall be guarded by an `actor`, every concurrent work stream shall be expressed as a `TaskGroup` or `AsyncStream`. There shall be no threads spawned by hand. There shall be no locks acquired by hand. There shall be no dispatch queues, no semaphores, no `@unchecked Sendable` cheats that subvert the compiler's concurrency guarantees. The compiler is our shield, and we shall not set it aside.

**Second Law — Swift Service Lifecycle, Without Exception.** Every long-lived component — the agent loop, the gateway, the cron scheduler, the kanban dispatcher — shall be a `Service` in a tree managed by `swift-service-lifecycle`. There shall be no ad-hoc daemon threads, no `atexit` cleanup handlers, no `DispatchMain()` calls that bypass the lifecycle framework. Startup is ordered, shutdown is graceful, and every service knows its place in the hierarchy.

These two laws are not goals. They are not aspirations. They are **requirements**. Code that violates them shall not be merged. Agents that generate code violating them shall be corrected. Humans that accept code violating them shall be reminded.

This is the contract. This is the foundation. Everything else is negotiable.

## Frontend Surface (Subsystem-Specific)

The frontend surface of ARC Agent is **SwiftUI**, delivered as an app that lives *outside* this package and embeds `ArcAgentCore` as a library target, in-process. The package exposes exactly one seam for it: the `ArcAgentCore` library product.

- `Sources/ArcAgentCore/UI/` holds the SwiftUI-style view DSL (View protocol, ViewBuilder, primitives, layouts, chat/bot views) preserved **verbatim with every line commented out** as reference for the external SwiftUI work. Do not delete it; do not uncomment it as a web UI.
- There is **no HTML, CSS, or JavaScript** in this project, and there shall be none. The web-UI serving stack — `/ui*` HTTP routes, the WebSocket server/handler, the asset pipeline, and the CSS/JS/HTML generation types — was removed in a single pass and must not be reintroduced.
- The HTTP server (Hummingbird) intentionally remains for the REST API (`/health`, `POST /v1/chat`) and the MCP/Messaging adapters. Hummingbird and swift-nio are infrastructure, not the UI surface.

## Design Temperament

- **Protocols first, macros last.** Every abstraction starts as a protocol. Concrete types conform to protocols; protocols do not depend on concrete types. Only after evaluating what becomes unwieldy as a result of this discipline do we introduce macros to make syntax perfectly efficient.

- **Swift-idiomatic first.** If a pattern from Hermes Agent fights Swift's type system or concurrency model, find the Swift-native alternative — don't force the Python shape into Swift code.

- **Compile-time over runtime.** Prefer generics, protocols, and macros over dictionaries and dynamic dispatch. A compile-time error is better than a runtime crash.

- **Minimal dependencies.** Every Swift package we add is a maintenance commitment. Before adding a dependency, ask: "Can we do this with Foundation + Swift Standard Library in 200 lines?"

- **Single binary target.** The goal is a precompiled binary you can `brew install` and run. No interpreter, no virtual machine, no npm install.

- **The UI ships as SwiftUI, not servable web.** The frontend surface belongs to an external SwiftUI app. If UI work must happen inside this package, it happens in the `UI/` reference DSL — and it stays commented out until the external app is wired up.

## What Success Looks Like

Success for the hardening phase is:

- A gateway that survives concurrent sessions without resource leaks
- Session data that survives process crashes without corruption
- Token budgets that are accurate enough to prevent context overflows
- Error recovery that makes transient failures invisible to the user
- Test coverage on every critical path
- Streaming responses from the gateway
- Structured logging and metrics that make the system observable

If we achieve that, the project is ready for additional platform adapters, distribution tooling, and eventual public release.
