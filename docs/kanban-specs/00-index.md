# Kanban Agent — Implementation Specs

Implementation-level specifications for `kanban-agent-design.md` (the settled
conceptual architecture). Each spec details one subsystem: concrete types,
record layouts, algorithms, edge cases, and test points. Where the design doc
leaves a decision open, the spec states the chosen default and flags it.

## Reading order

| # | Spec | Covers |
|---|------|--------|
| 01 | [Domain Model](01-domain-model.md) | Card, Column, Lane, Root, Lineage, readiness; the value types everything else builds on |
| 02 | [Column Graph](02-column-graph.md) | Graph storage, outcome vs policy edges, edit-time validation, mandatory columns |
| 03 | [Storage — Tessera](03-storage-tessera.md) | Record kinds, dTag layout, actor store, epochs, offline fallback |
| 04 | [Execution Engine](04-execution-engine.md) | Serial post-order traversal, root queue, drain rule, the run loop service |
| 05 | [Agent Verbs Protocol](05-agent-verbs.md) | The three verbs as structured tool calls, budgets, the child task contract |
| 06 | [Termination Artifacts](06-termination-artifacts.md) | Green evidence chain, yellow "what's missing" report, root resume |
| 07 | [Invariants Layer](07-invariants.md) | Cycle budgets, graph validation on edit, stale-motion fallback |
| 08 | [Web UI](08-web-ui.md) | Board rendering, graph editing, artifacts view |

## Cross-cutting ground rules (apply to every spec)

- **Storage is tessera** (signed NOSTR events via tessera-client), following the
  `TesseraCronStore` / `TesseraRecordIndex` patterns. No SQLite. `FileKanbanBoard`-
  style LOCAL fallback follows `StoreSelection` conventions.
- **Both Laws hold**: stores are actors; every long-lived loop is a `Service`
  in the daemon's service group; no hand locks or queues.
- **Swift 6 strict concurrency**; protocols first; compile-time over runtime.
- **TDD**: each spec's "Tests" section lists the suites that gate its phase.
- The engine is **fully serial** (§6 of the design doc) — this removes most
  concurrency hazards by construction; the specs lean into that.

## Implementation phases (proposed)

Build **all together, structure first**: the engine and storage are the
priority; the web UI lands in the same effort but yields if structure
demands the time. The order below is the dependency chain, not a gating
sequence — later phases start as soon as their inputs exist.

1. Domain model + storage (specs 01, 03) — cards are per-card tessera
   records (decision: answer 1); LOCAL fallback required but tessera is the
   primary (decision: answer 3).
2. Column graph + validation (spec 02) — the agent cannot edit the graph
   (decision: answer 11).
3. Execution engine with a **scripted judge** (spec 04) — multiple boards
   run concurrently, one active root each (decision: answer 15); card
   execution reuses the cron-style session machinery under the **board's
   selected profile** (decisions: answers 4, 5).
4. Agent verbs protocol (spec 05) — contract fields required, no quality
   heuristics; tokens burn freely (decisions: answers 6, 7).
5. Termination artifacts (spec 06) — explicit one-clause-per-line
   definition-of-done; optional resume context (decisions: answers 9, 12).
6. Invariants layer (spec 07) — triage auto-retries after a cooldown
   (decision: answer 10); all budget defaults live in `BoardSettings`
   (decision: answer 8).
7. Web UI (spec 08) — replaces the cosmetic kanban page; settings dropdown
   per board (decision: answers 8, 14).

The engine is built test-first against a `Judge` protocol (the decision-maker
interface the agent later implements), so the structure phases need no LLM
at all.
