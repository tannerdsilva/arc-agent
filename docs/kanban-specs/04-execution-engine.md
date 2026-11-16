# Spec 04 — Execution Engine

The serial run loop: post-order traversal within a root, root queue across
roots, the drain rule, and card execution. Source: design doc §5–§6, §9.
Second Law: the engine is a `Service`.

## 1. Single-writer discipline

All board mutations flow through the daemon's `KanbanEngineService` actor —
agent tools, CLI, and web UI call daemon endpoints; nobody writes the store
directly. The engine is the only writer, which replaces Hermes-style
write-locking with actor isolation.

**Multiple boards run concurrently** (one engine service, many boards):
each board advances its own root serially — design doc §6's "one root at a
time" holds *per board*, and separate boards run their roots in parallel.
The engine's tick is a `TaskGroup` over active boards; per-card execution
turns are independent, so no ordering hazard exists between boards.
A per-board `engineLease` (refreshed each tick, stored on the board
document) refuses a second daemon claiming the *same board*; different
boards may live on different daemons.

## 2. Traversal

Within the running root's tree (derived by walking `parentID` from
`firstCardID`, spec 01 §5):

- **Post-order depth-first, serially.** The next card to execute is the
  *deepest runnable* descendant not yet done: children before parents, since
  a parent consumes its children's outputs (design doc §6).
- Readiness drives the walk: a card is `runnable` when in an `agentWork`
  column, not `done`, and all of its children are `done`. A pending parent is
  `waitingOnChildren` — a stack frame; when its subtree drains it becomes
  `runnable` with its children's outputs as declared inputs.
- **Drain rule**: when a card finishes in a way the agent cannot fix, its
  siblings *still run* — the subtree drains before the root is judged. The
  engine implements this by never aborting a traversal on failure; failure is
  just an outcome that the judge routes (possibly to a failure column, whose
  subtree continues). There is no mid-subtree "is this fatal?" judgment.
- **Fan-out siblings** (Verb 2) join the fixed traversal order at their
  generation point — generation decides *what* exists, never scheduling.

```swift
func nextRunnableCard(in tree: [Card], on board: Board) -> Card?   // pure, testable
```

## 3. Root queue

- Non-terminal roots form a **fixed-order queue** (creation order by default).
  One root runs at a time; when a root reaches green/yellow the engine
  advances to the next.
- **Yellow roots exit the queue** (design doc §4): they park with their
  "what's missing" report and are resumable by the user (`resume` moves them
  back to the queue head, tree intact).
- Idling (all roots terminal, none resumable) is a *designed* state: the
  engine logs it and the web UI shows the "author new roots" signal.

## 4. The run loop (the Service)

```swift
public actor KanbanEngineService: Service {
    // tick-driven; default poll 5s, plus wake-on-event for daemon pushes
    func run() async throws   // until cancellation (graceful shutdown)
}
```

Each pass (per active board, fanned out in a `TaskGroup`):

1. **Load + validate**: board document, graph hard-rules (spec 02 §4 rules
   3, 9). Refuse to run an invalid board; log which rules fail.
2. **Advance timers**: `timerWait` columns whose deadline passed release their
   cards along the column's outgoing edge (policy `.fixed` semantics: the
   column's configured release edge; if none, the ask-the-user edge).
3. **Pick the next runnable card** in the running root's tree; if none and
   the root has unfinished work, that is the exhaustion point — go to
   Evaluate (spec 05 §4). If the root is fully terminal, advance the queue.
4. **Execute the card** (§5) → produce `CardResult`.
5. **Transition** the card (spec 05 §2 — deterministic first, then policy).
6. **Evaluate** the root at the generation point (spec 05 §4).
7. Persist board + events; loop.

Steps 4–6 are the three verbs; the engine orchestrates, the `Judge` decides.
Because multiple boards execute cards at once, the engine runs **one task
per executing card**, all inside the tick's `TaskGroup`; a board's own
traversal stays strictly serial (its next card is picked only after its
current card finishes).

## 5. Card execution

A card in an `agentWork` column runs its body as an **agent turn**:

- The card's `goal` + declared `input` (rendered per passing mode: reference
  → fetch the artifact and inline a pointer plus content; summary/inclusion →
  inline text) + `doneCondition` become the task prompt.
- The turn runs in the **board's configured profile** (`BoardSettings.profile`,
  spec 01 — selected per board by the user), with the same standing-context
  rules as cron (system prompt, skills, workspace; no cross-run transcript
  history).
- The turn's final structured output is the `CardResult`
  (`outcome` label + summary). The outcome label *should* name a
  deterministic edge from the current column when one matches — the judge
  enforces that mapping (spec 05 §2), so the executor's label is a claim the
  transition step verifies.
- Raw outputs (logs, diffs) are stored as artifacts; the result summary stays
  short (bodies readable, board legible).

**Executor implementation** reuses the daemon's session/turn machinery (the
same path cron jobs use), not a new runner. `no_agent`-style script cards are
*out of scope for v1* — flagged, revisit if wanted.

## 6. Saturation and stalls

- Occupancy comes from the traversal itself; there is no scheduler beyond
  "next runnable card." A root with no runnable card and no budget is the
  exhaustion evaluation — never a silent stall (design doc §5 Verb 3).
- **Stale-motion fallback** (invariant 4): if the judge is unavailable
  (LLM unreachable), a card finishing in a work column moves along its
  column's `defaultEdgeID` after a timeout (`staleMotionTimeout`, board
  setting, default 10 min), `decidedBy: .fallback` stamped in provenance. The
  board moves; the user sees fallback stamps; nothing silently spins.

## 7. Tests

- `nextRunnableCard` property tests: post-order on arbitrary generated trees
  (children strictly before parents; siblings in generation order).
- Drain rule: fixture with one failing + one independent sibling — the
  sibling still runs; root evaluated once, after drain.
- Root queue: green/yellow advance; yellow removes from queue; resume
  returns it at head.
- Timer release, stale-motion fallback (judge unavailable → default edge
  after timeout, provenance stamped).
- Engine lease: second daemon refused on the *same board*; different boards
  on different daemons allowed.
- Two boards run concurrently with independent roots (scripted judge): both
  advance in the same tick group without cross-board interference; each
  board's traversal remains strictly serial.
- Full-loop integration with a scripted `Judge` (no LLM): root with a
  two-level tree runs to green against a fixed verdict script.
