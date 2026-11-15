# ARC Agent — AGENTS.md

## Project Phase: Vascular Hardening — client eradication complete

This project has completed five feature-build phases and, on 2026-11-14, closed the **client-overlay eradication program**: `Sources/ArcWebUI/Assets/overlay.js` (1,642 lines / 73,214 bytes) is deleted, every client consequence it carried is a no-webui behaviour, and `ZeroClientScriptTests` fails the suite if a `.js` file ever reappears under `Sources/`. The project remains in **vascular hardening** — strengthening the internal data flow, session integrity, error recovery, and observability before adding new capabilities.

The core architecture is built and proven:
- **278 Swift source files** across eight target directories — ArcAgentCore (203), ArcWebUI (46), the `arc-agent` CLI (15), ArcTheme (5), ArcToolKit (5), ArcDaemon (2), ArcAssetTool (1), and ArcSubprocessFixture (1, a test-only process-group fixture)
- **Swift 6 language mode** — every target compiles under Swift 6 strict concurrency (no `.swiftLanguageMode(.v5)` pins remain). The build is error-free; the compiler emits 6 `#UnnecessaryEffectMarker` notes from `Views.swift` (an `await` with no async work in ViewBuilder closures), and SwiftPM warns about a `swift-syntax` package-identity conflict through quicklmdb/nostr-kit versus no-webui/swift-mcp
- **1,978 executed tests** — 1,178 core (172 suites) + 785 web UI (112 suites) + 15 daemon (2 suites); 1,179 / 785 / 15 `@Test` declarations. The environment-gated core test reads the live `~/.arc/config.json` (aux layout, reference endpoints); it passes on this configured host and is the only test that can go red on a machine configured with a different provider
- **16 dependencies** (AsyncHTTPClient, ArgumentParser, System, ServiceLifecycle, tessera, Hummingbird, swift-mcp, swift-nio, swift-nio-ssl, swift-nio-extras, swift-http-types, SwiftSlash, swift-log, swift-crypto, no-webui, ArcSidebarTabs — tessera and ArcSidebarTabs are **local path pins** while they are co-developed; no-webui is **revision-pinned** at `f286006` = tag `3.1.0`)
- **54 built-in tool registrations** across 16 toolsets (52 always on; `send_bot_message` and `send_group_chat` exist only when the messaging services are configured). Arc parity includes `project_*`, `skill_manage`, `skills_list`, `tool_search`, `send_message`, `mcp_tool`; `execute_code` is arc's own; the reference media/webhook ports stay deleted
- **Zero hand-written client JS** — the web UI's entire client is no-webui's engine (`/ui/webui-engine.js` + `-ext`); arc's last 60 lines became `data-open` layers, a native radio group and a CSS transition, and `ZeroClientScriptTests` enforces the absence
- **Gateway stack** — HTTP server (:8080), Telegram adapter, MCP server, session management
- **Tessera-backed persistence** — sessions and memory stored as signed NOSTR events through the tessera-client library
- **Swift-native web UI** — declarative Swift DSL generating HTML/CSS, embedded in the binary and served by the daemon itself (`arc serve` mounts `Sources/ArcWebUI/WebUIHost.swift` on no-webui's `WebUIServer`: web UI on :8890, HTTP API on :8080). Zero npm, zero hand-written web code, zero client script; the one asset (the sheet) is a build product of `ArcAssetPlugin` + `ArcAssetTool`

## What This Means for an AI Agent Reading This

You are working in a **functional codebase with a clear hardening roadmap**. The architecture is documented in VISION.md. The two Laws are enforced, and the client-side eradication program is closed. Your job is to help harden the existing system — not to add features, but to make the existing pipes reliable, observable, and resilient. A new `.js` under `Sources/` is a design regression, not a feature.

When asked to produce code, assume it is:
- **Hardening-focused** — strengthening existing paths, not building new ones
- **Test-driven** — every change should be verified by tests
- **Observable** — add logging, metrics, or error classification alongside functional changes

## Current State

| What | Status |
|---|---|
| VISION.md | Architecture + hardening roadmap |
| AGENTS.md | This file |
| README.md | Updated |
| Source files | 278 Swift files in `Sources/` (ArcAgentCore 203, ArcWebUI 46, arc-agent CLI 15, ArcTheme 5, ArcToolKit 5, ArcDaemon 2, ArcAssetTool 1, ArcSubprocessFixture 1) |
| Tests | 1,978 executed (1,178 core in 172 suites + 785 web UI in 112 suites + 15 daemon in 2 suites); the environment-gated live-config test passes on this host and is the only expected red on a differently-configured one |
| Client JS | **Zero** — `ZeroClientScriptTests` fails on any `*.js` under `Sources/`, a non-empty asset manifest, or an arc script tag in the served document |
| no-webui pin | revision `f286006` = **3.1.0** (annotated tag, pushed to origin) |
| Build | Error-free in Swift 6 language mode; 6 `#UnnecessaryEffectMarker` notes from `Views.swift`; SwiftPM `swift-syntax` identity warnings through the dependency graph |
| Branch | `tessera` (active — 106 commits ahead of `dev`; `master` is the base of both) |

## Subsystem Inventory (highlights)

| Subsystem | Location | Status |
|---|---|---|
| **Core Agent** — ArcAgent actor, prompt builder, turn loop | `Agent/ArcAgent.swift` | Built |
| **Tool Registry** — ToolEntry, JSONSchema, CompileTimeToolRegistry | `ToolRegistry/` | Built |
| **Tools** — 54 built-in registrations (file, terminal, web, delegation, kanban, memory, skill_view, unified skill_manage, skills_list, profile_edit, clarify, browser/CDP, patch, search_files, execute_code, project_*, tool_search, send_message, mcp_tool, …) | `Tools/` | Built |
| **LLM Client** — LLMClient protocol, adapters (OpenAI, Anthropic, Gemini, Bedrock, Vertex, ACP, Codex) | `LLM/` | Built |
| **Provider System** — ProviderProfile, BundledProviders, CredentialPool | `Provider/` | Built |
| **Session Management** — SessionStore protocol, TesseraSessionStore | `Session/` + `Storage/` | Built |
| **Memory System** — MemoryProvider protocol, TesseraMemoryProvider, FileMemoryProvider | `Memory/` + `Storage/` | Built |
| **Skills System** — Skill model, YAML frontmatter parsing, discovery | `Skills/Skill.swift` | Built |
| **Security** — ApprovalManager, HardlineBlocker (Layer 1), SoftDetector (Layer 2), ExecutionFlagDetector (Layer 3), ShellLexer, AgentPowers lockdown gate | `Security/` | Built |
| **Error Handling** — RetryHandler, CircuitBreaker, Failover, RecoveryState | `ErrorHandling/` | Built |
| **Delegation** — DelegationManager, subagent spawning/steering/stopping | `Delegation/` | Built |
| **Kanban** — KanbanBoard protocol, FileKanbanBoard, KanbanDispatcher | `Kanban/` | Built |
| **Cron** — CronScheduler, CronJob, schedule parsing | `Cron/` | Built |
| **Gateway** — GatewayService, HTTPServerService, SessionRegistry, SessionAgent, TelegramAdapter, DeliveryManager, SessionRouter, PlatformAdapter, ProfileRouting | `Gateway/` | Built |
| **MCP** — MCPServerAdapter, DynamicMCPTool | `Gateway/MCP/` | Built |
| **Tessera** — TesseraConnection (shared tunnel), TesseraSessionStore, TesseraMemoryProvider | `Storage/` | Built |
| **Web UI** — AppState, Actions, Views, Theme (chrome), ThemeCatalog (27 schemes), Queue, NewFeatures, Insights, BuiltInSidebarTabs, SidebarTabBridge, SidecarPlugin, WebUIHost; the client is no-webui's engine; typed components (`UploadZone`, `ChatScroller`, `ComposerText`) carry behavior attributes in their own open tags | `Sources/ArcWebUI/` + `Sources/ArcTheme/` | Built |
| **Client consequences** — no-webui 3.1.0 behaviors: upload zones, scroll follow + reading keys, focus return/into/appear, dismiss stack + drawer, draft identity/seed, submit modes + clear-on-submit, theme `aria-pressed`, `FilterList` slash palette, clipboard + toast | `Sources/ArcWebUI/Components/` + empty asset manifest | Built |
| **Sidebar Tab Plugins** — `SidebarTab` protocol kit (`Plugins/ArcSidebarTabs`, dependency-free), sidecar plugin host bridge + built-in adapters (`SidebarTabBridge.swift`, `BuiltInSidebarTabs.swift`), Settings → Sidebar plugins | `Plugins/` + `Sources/ArcWebUI/` | Built |
| **Shared renderers** — arc-parity markdownToHTML + MarkdownRenderer + highlightCode + URL/HTML sanitizers; the WebSocket transport itself is no-webui's `WebUIServer` | `ArcAgentCore/WebUI/Utilities.swift` (1 file) | Built |
| **Compression** — MicroCompactor (per-turn transcript absorption) | `Compression/` | Built |
| **Bot Mode** — Profile struct, ProfileManager, BotMessagingService, GroupChatRoom | `Profile/` | Built |

## How We Work

1. **Vascular first.** Every change should improve the flow of information through the system — making it more reliable, observable, or resilient. If a change doesn't improve the vascular system, question whether it belongs in this phase.

2. **Test before hardening.** Write the test that proves the current behavior is wrong, then fix the code. Tests are the diagnostic monitors on the vascular system.

3. **One program at a time.** The overlay-eradication program closed on 2026-11-14; hardening work continues in slices, each with its own gate. The record is mechanical: `make verify` (three suite runs), `node Scripts/ux-gates.mjs` (the browser matrix), and `Scripts/ship-gate.sh` (the consolidated ship gate).

4. **Commit early, commit often.** Each hardening step is a separate commit with a clear before/after. The `tessera` branch is the active development branch.

5. **The Laws are not negotiable.** First Law (Structured Concurrency) and Second Law (Service Lifecycle) are enforced at every level. Code that violates them shall not be merged.

## The Law of the Land

HEAR YE, HEAR YE. In this beautiful project, of which we are so proud, there shall be a law of the land, of which all agents and humans alike shall abide unconditionally at all times. THE LAW OF THE LAND IS SIMPLE, AND AS FOLLOWS:

**First Law — Swift Structured Concurrency, Without Exception.** Every fiber of this codebase shall run on `async`/`await`, every mutable state shall be guarded by an `actor`, every concurrent work stream shall be expressed as a `TaskGroup` or `AsyncStream`. There shall be no threads spawned by hand. There shall be no locks acquired by hand. There shall be no dispatch queues, no semaphores, no `@unchecked Sendable` cheats that subvert the compiler's concurrency guarantees. The compiler is our shield, and we shall not set it aside. (Known, accepted exceptions: Tessera/storage and CDP browser internals use a small number of `@unchecked Sendable`/lock workarounds documented in code.)

**Second Law — Swift Service Lifecycle, Without Exception.** Every long-lived component — the agent loop, the gateway, the cron scheduler, the kanban dispatcher — shall be a `Service` in a tree managed by `swift-service-lifecycle`. There shall be no ad-hoc daemon threads, no `atexit` cleanup handlers, no `DispatchMain()` calls that bypass the lifecycle framework. Startup is ordered, shutdown is graceful, and every service knows its place in the hierarchy.

These two laws are not goals. They are not aspirations. They are **requirements**. Code that violates them shall not be merged. Agents that generate code violating them shall be corrected. Humans that accept code violating them shall be reminded.

This is the contract. This is the foundation. Everything else is negotiable.

## Web UI Law (Subsystem-Specific)

**Second Law (Web UI) — No npm, No Exceptions.** There shall be no `npm install`, no `package.json`, no `node_modules`, no webpack, no vite, no tailwind, no react, no vue, no svelte, no solid, no alpine, no stimulus, no htmx, no turbolinks, no hotwire, no stimulus_reflex. There shall be no JavaScript framework, no CSS preprocessor, no build pipeline. The web UI is generated by Swift code in `Sources/ArcWebUI/` — the CSS it needs is Swift string constants, and it needs no JavaScript of arc's own at all:

- `Theme.swift` — arc's chrome stylesheet, pure Swift strings; `Sources/ArcTheme/ThemeCatalog.swift`
  — the 27 schemes as no-webui providers
- The client runtime is **no-webui's engine** (`/ui/webui-engine.js` + its `-ext` asset, routed by
  `WebUIServer`). **Arc has no client script**: every client consequence is a framework behavior
  (`data-open`, `data-follow`, `data-reading-keys`, `data-draft-id`/`data-draft-value`,
  `data-submit-on-enter`, `data-focus-return`/`data-focus-into`/`data-focus-on-appear`,
  `data-dismiss`, `data-copy`, `data-filter-list`, the upload zones). `ZeroClientScriptTests`
  fails the suite if any `*.js` appears under `Sources/`, if the asset manifest embeds anything,
  or if the served document carries an arc script tag.
- Generated assets are **build products, never checked in**: `ArcAssetPlugin` runs `ArcAssetTool`
  before every build of the web UI target — `theme-sheet` embeds the rendered stylesheet with its
  sha256 content address and its gzip. The asset manifest (`Assets/webui-assets.json`) is empty.

There is no "disk mode": every asset is compiled into the binary. Chat markdown is rendered server-side by the shared arc-parity renderer (`ArcAgentCore/WebUI/Utilities.swift`), then enhanced client-side by the engine (table sort/filter via `data-table-enhance`). There is no KaTeX.

## Command Security Layers

Terminal-command gating is a three-layer pipeline in `Sources/ArcAgentCore/Security/` (ported from Hermes `approval.py`):

1. **Layer 1 — `HardlineBlocker`.** Twelve catastrophic patterns (root/system-dir/home deletion, block devices, fork bombs, `kill -1`, kernel shutdown, `sudo -S`). **Unconditional denial, above every mode** — YOLO/`.off`, the always-allow list, pre-approved sessions, and a human pressing "approve" can never execute a hardline command. Denial text names the hit ("hardline: recursive delete of root filesystem").
2. **Layer 2 — `SoftDetector`.** The 77 Hermes `DANGEROUS_PATTERNS` verbatim (hermes-specific rules remapped to `arc serve` / `~/.arc/config.json`) plus an arc-legacy extras tier (generic `kill`/`pkill`/`killall`/`sudo`). Flagged commands: `.off` → approved (YOLO), `.manual` → human prompt, `.smart` → aux classifier arbitrates (first-word verdict parsing; prose verdicts fall back to prompt). Unflagged commands never prompt in any mode.
3. **Layer 3 — `ExecutionFlagDetector`.** Quote-aware structural detection: interpreter `-c`/`-e` eval payloads, `bash -c` body rescan, read-tool exec flags (`jq -f`, `git -c`, `ssh -o`), and parser-limit fail-closed guards. `ShellLexer` is the shared substrate (shlex-compatible tokenizer, deobfuscation, detection variants). `rm -f $TMPDIR/arc-verify-*` (verification-artifact cleanup) is the only exemption.

The two Laws apply — all detection runs through immutable compiled patterns (`SecurityRegexStore`, documented thread-safe) with no locks or queues.

## Design Temperament

- **Protocols first, macros last.** Every abstraction starts as a protocol. Concrete types conform to protocols; protocols do not depend on concrete types. Only after evaluating what becomes unwieldy as a result of this discipline do we introduce macros to make syntax perfectly efficient.

- **Swift-idiomatic first.** If a pattern from the reference agent fights Swift's type system or concurrency model, find the Swift-native alternative — don't force the Python shape into Swift code.

- **Compile-time over runtime.** Prefer generics, protocols, and macros over dictionaries and dynamic dispatch. A compile-time error is better than a runtime crash.

- **Minimal dependencies.** Every Swift package we add is a maintenance commitment. Before adding a dependency, ask: "Can we do this with Foundation + Swift Standard Library in 200 lines?"

- **Single binary target.** The goal is a precompiled binary you can `brew install` and run. No interpreter, no virtual machine, no npm install. One `arc` binary; the daemon serves both the web UI and the HTTP API, and shared logic lives in ArcAgentCore.

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
- A web UI whose entire client is the framework's engine — zero hand-written JS, enforced by
  `ZeroClientScriptTests` and the consolidated `Scripts/ship-gate.sh`

If we achieve that, the project is ready for additional platform adapters, distribution tooling, and eventual public release.
