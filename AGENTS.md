# ARC Agent — AGENTS.md

## Project Phase: Blue Sky

This project is in its **blue sky phase**. We are working with concepts, not code. The `VISION.md` describes what ARC Agent *could* become — a precompiled, Swift-native AI agent harness — but nothing here is built yet. Every line in this repository is an idea, a sketch, a hypothesis.

The approach is **incremental proof-building**: each subsystem described in the vision will be explored, prototyped, and validated one piece at a time. Some ideas will survive contact with reality. Some will be discarded. The architecture will shift as we learn what Swift's concurrency model, type system, and ecosystem make easy versus hard.

## What This Means for an AI Agent Reading This

You are working in an **empty repository with a vision document**. There is no code to read, no tests to run, no build to fix. Your job is to help the human explore, design, and prototype — not to maintain or debug an existing system.

When asked to produce code, assume it is:
- **Exploratory** — meant to validate an approach, not ship to production
- **Subject to change** — the architecture is fluid; don't over-invest in one design
- **Conceptually focused** — prove the idea works; edge cases come later

## Current State

| What | Status |
|---|---|
| VISION.md | Written, committed |
| AGENTS.md | This file |
| README.md | Written |
| Code | None |
| Tests | None |
| Build | None |

## How We Work

1. **Explore a subsystem** from the vision document. Discuss the design, trade-offs, and Swift idioms before writing code.
2. **Prototype the core** of that subsystem — enough to validate the approach. A working `ToolRegistry` with 3 tools is worth more than a full spec for all 30.
3. **Iterate** based on what the prototype reveals. The architecture document is a living artifact; update it when reality contradicts the plan.
4. **Commit early, commit often.** Each prototype lives on its own branch or behind a feature flag. The `main` branch stays conceptual (docs only) until we have enough working pieces to call it an alpha.

## The Law of the Land

HEAR YE, HEAR YE. In this beautiful project, of which we are so proud, there shall be a law of the land, of which all agents and humans alike shall abide unconditionally at all times. THE LAW OF THE LAND IS SIMPLE, AND AS FOLLOWS:

**First Law — Swift Structured Concurrency, Without Exception.** Every fiber of this codebase shall run on `async`/`await`, every mutable state shall be guarded by an `actor`, every concurrent work stream shall be expressed as a `TaskGroup` or `AsyncStream`. There shall be no threads spawned by hand. There shall be no locks acquired by hand. There shall be no dispatch queues, no semaphores, no `@unchecked Sendable` cheats that subvert the compiler's concurrency guarantees. The compiler is our shield, and we shall not set it aside.

**Second Law — Swift Service Lifecycle, Without Exception.** Every long-lived component — the agent loop, the gateway, the cron scheduler, the kanban dispatcher — shall be a `Service` in a tree managed by `swift-service-lifecycle`. There shall be no ad-hoc daemon threads, no `atexit` cleanup handlers, no `DispatchMain()` calls that bypass the lifecycle framework. Startup is ordered, shutdown is graceful, and every service knows its place in the hierarchy.

These two laws are not goals. They are not aspirations. They are **requirements**. Code that violates them shall not be merged. Agents that generate code violating them shall be corrected. Humans that accept code violating them shall be reminded.

This is the contract. This is the foundation. Everything else is negotiable.

## Design Temperament

- **Swift-idiomatic first.** If a pattern from Hermes Agent fights Swift's type system or concurrency model, find the Swift-native alternative — don't force the Python shape into Swift code.
- **Compile-time over runtime.** Prefer generics, protocols, and macros over dictionaries and dynamic dispatch. A compile-time error is better than a runtime crash.
- **Minimal dependencies.** Every Swift package we add is a maintenance commitment. Before adding a dependency, ask: "Can we do this with Foundation + Swift Standard Library in 200 lines?"
- **Single binary target.** The goal is a precompiled binary you can `brew install` and run. No interpreter, no virtual machine, no npm install.

## What Success Looks Like

Success is not "shipping ARC Agent v1.0." Success is:

- Proving that a Swift-native agent harness can match Hermes Agent's capabilities with a fraction of the startup time and memory footprint
- Building a tool registry that catches schema errors at compile time
- Demonstrating that Swift's structured concurrency produces cleaner delegation and kanban dispatch than Python's threading + asyncio hybrid
- Reaching a point where the human can run `arc chat -q "hello world"` and get a response from an LLM through their own Swift code

If we achieve that, the project may become something real. If we don't, we'll have learned exactly where the limits are — and that knowledge is valuable too.

---

*This file is read by AI agents working on this project. Keep it honest about what phase we're in. Pretending the project is further along than it is wastes everyone's time.*
