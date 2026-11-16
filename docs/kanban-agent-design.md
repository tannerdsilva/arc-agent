# Kanban Agent — Design Document

High-level design for an agent-driven kanban board that keeps an agent
continuously occupied with work. No implementation details; this document is
the settled conceptual architecture from the design brainstorm.

The board is a **state machine the user draws**, and the agent **plays the
game within it**: moving cards, authoring successor tasks, and judging when a
goal is satisfied. The board is not a queue of user requests — it is an
execution trace, materialized as cards.

---

## Table of Contents

1. [Board Structure](#1-board-structure)
2. [Column Graph](#2-column-graph)
3. [Card Anatomy and Lineage](#3-card-anatomy-and-lineage)
4. [Root Tasks](#4-root-tasks)
5. [The Agent's Three Verbs](#5-the-agents-three-verbs)
6. [Execution Model](#6-execution-model)
7. [Termination: Green and Yellow](#7-termination-green-and-yellow)
8. [Invariants](#8-invariants)
9. [The Full Loop](#9-the-full-loop)
10. [Open Questions](#10-open-questions)

---

## 1. Board Structure

The board is a grid of **any number of lanes** and **any number of columns**.
Both axes are structural — there is no fixed set of states built into the
engine.

- **Columns** carry the workflow semantics. Their names and meanings are
  authored by the user (for example, a board might have columns like
  "Running," "Failed (compile issue)," "Failed (runtime issue)," "Succeeded").
  These names are examples only; nothing in the design depends on specific
  column names or a specific set of columns.
- **Lanes** are purely structural. The agent decides what goes in which lane.
  Lanes have no semantics the engine depends on. A side effect worth keeping:
  lane assignments become the agent's organizational memory — the lane layout
  is a living map of how the agent is thinking about the work. Lane
  assignments should be visible and stable; the agent should not reshuffle
  them silently every tick.

Every column has a **kind**, which determines how cards move out of it:
agent-work, human-wait, timer-wait, or terminal. The graph is the shape; the
kinds are the physics.

**Card position vs. card state.** A card's position is (lane, column). Under
that sits a separate *readiness* dimension: runnable, waiting-on-children,
running, done. Columns describe workflow position; readiness describes whether
the card can execute. Keep them conceptually separate.

## 2. Column Graph

Columns are **nodes in a directed graph**; transitions are **edges**. There is
no hardcoded sequence. The graph permits:

- **Arbitrary fan-out** — one column may have many outgoing edges. For
  example, a "Running" column might lead to "Failed (compile issue)," "Failed
  (runtime issue)," and "Succeeded." This is an example verdict branch, not a
  required shape.
- **Arbitrary fan-in** — multiple columns may feed one column. For example,
  both failure columns above might lead to a "Rerun" column. Merging must
  preserve the card's memory of *which* edge brought it there (see §3).
- **Cycles** — legitimate and necessary (retry loops require them). Cycle
  safety is handled by the invariant layer (§8), not by forbidding cycles.

**Two edge types:**

1. **Outcome edges (deterministic).** The result itself determines the
   destination — a fact, not a choice. A task ending with a compile error
   *must* land in the corresponding failure column, when such an edge exists
   and is marked deterministic. The transition is a mapping: outcome → column.
2. **Policy edges (chosen).** Multiple destinations are both valid; someone
   must choose — a fixed rule, a counter, or the agent's judgment. These
   edges carry a decision policy, not just a destination.

Edges may be marked **deterministic** by the user; the agent skips judgment
on those entirely. Judgment is reserved for edges marked as agent-decided.
The agent is the **transition function** for those: it receives (task, output,
available edges) and must choose exactly one legal edge. Forcing a choice
among legal edges keeps the invariant intact.

The graph is **user-editable at any time**. Editing the graph is how new
failure modes, new stages, or new workflows get added without code changes.

## 3. Card Anatomy and Lineage

A card carries:

- **Position** — (lane, column), plus its readiness state.
- **Body** — the work to be done, under the task contract (§5, Verb 2).
- **Lineage** — parent id, the edge it was born along, and *why* the agent
  believes this work is next. The upward walk from any card is its full
  justification — the chain of cards is the reasoning path that produced it.
- **Last-edge memory** — which transition brought the card to its current
  column. Merging columns (fan-in) must not erase this; a card that arrived
  via "Failed (compile issue)" must remember it, or retries become amnesia.
- **Transition provenance** — the reasoning for each move, attached to the
  card. When someone asks why a card is where it is, the answer is on the
  card, not lost in a session.
- **Traversal counts** — per-card history of column re-entries, feeding the
  cycle budget (§8).
- **Attachments** — raw outputs (diffs, logs, dumps) live here, not in the
  card body. Card bodies stay readable; the board stays legible.

**Output passing** between parent and child is a context decision, with three
modes — all may be needed:

- **By reference** — the child gets a pointer and reads the output from
  storage when working. For large outputs.
- **By summary** — the agent distills the output into the child's body.
  Lossy, but keeps cards readable.
- **By inclusion** — raw copy, only for small outputs.

Whichever mode is used, it is **declared** on the child — nothing is silently
lost.

## 4. Root Tasks

- **Only the user creates root tasks.** This keeps *intent* human-owned while
  *execution planning* is agent-owned. It is a core invariant, not a default.
- Each root carries a **definition-of-done** — the constitution the agent
  judges against at every evaluation. A vague root produces mushy trees; a
  root with a real, checkable done-condition produces completable ones.
- A root's tree of descendants is the agent's plan for that root, grown
  generation by generation. The tree, not any single card, is the working
  unit.

**Root lifecycle:**

1. **Created** by the user, with a definition-of-done.
2. **Running** — the agent walks its tree serially (§6).
3. **Terminal** — exactly one of:
   - **Green** — "goal met." Closed forever. Carries an evidence chain:
     which completed descendants satisfied which clauses of the
     definition-of-done. This evidence is what the user reviews to trust or
     distrust a green.
   - **Yellow** — "incomplete, needs further analysis." There is deliberately
     no red "impossible" state: the agent never declares failure, it declares
     *insufficiency*, and feasibility authority stays with the user.
     - Yellow is a **park, not a corpse**: the tree freezes in place, and the
       full record — the chain built, what was tried, where it got stuck —
       stays on the board. The natural next step is the user resolving the
       blocker and **re-activating** the root; work resumes with prior
       results intact.
     - A yellow root must carry a **structured "what's missing" report**:
       what was attempted, what the blocking unknown is, and what the user
       would need to provide (a decision, a credential, information, or a
       capability the graph doesn't have). Without this, "yellow" degenerates
       into "agent gave up." The report is required, not optional.
     - Yellow roots **exit the running queue** so they do not block roots
       behind them; they live in a separate "needs user" pile until resumed.

**Root verbs for the user:** create, review, resume.

## 5. The Agents Three Verbs

The agent has exactly three acts on the board. They have different risk
profiles and different rules, and the permission gradient follows the risk
gradient: **transition freely, generate under budget, evaluate always.**

### Verb 1 — Transition *(low risk, no gate)*

*Move a completed card along a legal edge to its next column.*

- **Fires:** every time a card finishes executing. The most frequent act.
- **Judgment:** which outcome the card's result represents — classification,
  not creativity.
- **Constraints:**
  - The destination must be an existing edge from the current column. The
    agent cannot invent a destination.
  - The transition reasoning is attached to the card (provenance).
  - Deterministic edges bypass the agent entirely.
  - If multiple edges genuinely match, the tie-break rule applies: outcome
    edges before policy edges; if still ambiguous, a designated fallback
    column or the agent's annotated best guess.
- **Why no gate:** a wrong transition is recoverable — the card can be moved
  again, and the attached reasoning shows what happened. Requiring permission
  to classify a result would make the system sluggish for zero safety gain.

### Verb 2 — Generate *(high risk, budgeted)*

*From a completed card, author a new child task whose input is the parent's
output, placed along a legal edge.*

- **Fires:** when the root is not yet satisfied and more work is needed — a
  chain continuation or a fan-out of siblings.
- **Judgment:** what the next piece of work *is* — planning, not
  classification. This is the agent acting as a task author, the
  highest-authority verb.
- **The child task contract** (the quality gate — every generated task must
  state all three):
  1. **Goal** — what this card tries to accomplish. Specific, never "continue
     work."
  2. **Input** — what from the parent's output it builds on, and the passing
     mode (reference / summary / inclusion).
  3. **Done-condition** — how completion will be recognized. Checkable, not
     vibes.

  Agents forced to write done-conditions produce completable chains; agents
  that write vague tasks produce vague chains. The contract is also what
  makes the yellow report analyzable later.
- **Lineage stamp:** parent id, birth edge, and the reason this work is next.
- **Budget (the runaway control):**
  - A **per-chain depth cap** — maximum generations from a root before
    forced evaluation.
  - The **always-legal exits** (ask the user, yellow the root) are available
    from anywhere, so the agent is never trapped into generating when it
    should not.
  - The budget is also a *forcing function for judgment*: a finite minting
    allowance makes each minting decision deliberate.
- **Placement:** generated siblings join the fixed serial traversal order.
  Generation decides *what* work exists; it never creates a scheduling
  problem.
- **Why budgeted:** a wrong transition loses a card's position; a wrong
  generation loses money and time, and compounds.

### Verb 3 — Evaluate *(highest risk, self-correcting, mandatory artifacts)*

*Check the root's definition-of-done against the state of the whole tree.*

- **Fires:** at every generation point — each time a card completes and the
  agent decides between transition, generate, and stop — and at the
  **exhaustion point**: no workable card, no budget remaining, root not
  satisfied. The exhaustion case is a *designed* evaluation, not a failure.
- **The three-way verdict:**
  - **Continue** — the goal is not met but a viable next move exists; return
    to Verb 1 or Verb 2.
  - **Green** — the goal is met; emit the evidence chain (§4).
  - **Yellow** — incomplete; emit the structured "what's missing" report
    (§4) and exit the running queue.
- **Constraints:**
  - The judgment is always against the **root's** definition-of-done, never
    against any single card's completion. A card being done is mechanical;
    the root being satisfied is judgment.
  - The agent never declares "impossible" — only "insufficient."
  - The evidence chain (green) and the report (yellow) are **required
    artifacts**. A green without evidence is just an assertion; a yellow
    without a report is just giving up. The artifacts are what make the
    verdicts trustworthy.
- **Why it is safe despite being the highest-stakes judgment:** both wrong
  verdicts are visible and reversible — the user reviews greens, and yellows
  are resumable. The truly dangerous outcomes (silent spin, silent stall) are
  structurally prevented: "no viable move" is itself an evaluation with a
  required output (yellow + report), so the agent can never quietly do
  nothing.

## 6. Execution Model

**Fully serial.** No parallelism anywhere in the design.

- **Within a root:** post-order depth-first traversal. To build A, where A
  needs B and C first, the order is B → C → A — A executes after its children
  because it consumes their outputs. A pending parent is a stack frame
  waiting on returns; its readiness is "waiting-on-children" until its
  subtree drains, then it becomes runnable with its children's outputs as
  inputs. (The A/B/C structure here is an example decomposition; the agent
  may decompose any way it chooses, and may fan out multiple children from
  one parent.)
- **Across roots:** roots run **to completion in fixed order** — a job queue
  of intents. One root at a time; no stepping on toes, no concurrency
  machinery at all.
- **The mid-tree failure rule — drain, not short-circuit:** when a card fails
  in a way the agent cannot fix, its siblings **still run**. The subtree
  drains before the root is judged. Rationale:
  - A sibling may be independent, and its output may still be useful — for
    the parent, for a later retry, or for the yellow report.
  - Drain reuses existing machinery: the root is evaluated once, at the
    natural point, with complete information. Short-circuiting would require
    a second kind of mid-subtree judgment ("is this failure fatal to the
    root?") made with incomplete information — exactly the kind of
    speculative judgment that throws away salvageable work.
  - Drain composes with yellow: a failed child plus a drained sibling yields
    a rich report, and on resume the sibling's output is already done.

**Saturation:** the agent is occupied as long as *some* root has a runnable
card. Continuous occupancy is achieved by the combination of serial
traversal (no idle gaps from scheduling), root queueing (a finished root
hands off to the next), and the yellow rule (a root that cannot progress
exits to the user rather than occupying a slot doing nothing).

## 7. Termination: Green and Yellow

Consolidated from §4 — the two terminal states of a root:

| Verdict | Meaning | Required artifact | Aftermath |
|---|---|---|---|
| **Green** | Root definition-of-done satisfied | Evidence chain: which descendants satisfied which clauses | Closed permanently; user reviews evidence |
| **Yellow** | Incomplete; needs further analysis | Structured report: attempts, blocking unknown, what the user must provide | Exits running queue; resumable by the user |

There is no red state. The agent declares insufficiency, never impossibility.

## 8. Invariants

A small invariant layer sits **below** both the user and the agent. Neither
can override these; they keep the graph's freedom from becoming chaos.

1. **Cycle budgets.** Cycles are allowed and necessary, but unbounded cycling
   is not: per-card traversal counts (or an equivalent budget) trigger
   routing to a mandatory **triage** column when the same column is re-entered
   too many times. Reset only on genuine progress, never on the cycle itself —
   resetting on re-entry is the amnesia that lets loops run unbounded.
2. **Graph validation on edit.** Every path in the user's graph must reach a
   terminal column, and every column must be reachable from an entry point.
   Warnings are issued when a graph edit breaks this.
3. **Mandatory columns.** The board must always contain a triage column and
   an **"ask the user"** move that is legal from every column — stopping to
   ask is a legal move everywhere, not a failure state.
4. **Stale-motion fallback.** Board motion must not depend on any single
   component being alive. If the judging agent is unavailable, cards finishing
   in a work column move along a designated default edge after a timeout,
   rather than stalling the board.
5. **Lineage is immutable.** Parent links, birth edges, and last-edge memory
   are never erased — by merges, retries, or lane reshuffles.
6. **Only the user creates roots.** The agent generates descendants only.

## 9. The Full Loop

> Card completes → **Transition** it (classify the outcome along a legal
> edge) → **Evaluate** the root (continue / green / yellow) → if continue:
> **Generate** the next card(s) under contract and budget → serial traversal
> advances to the deepest runnable card in the current root's tree → repeat.
>
> When a root terminates: green closes it with evidence; yellow parks it with
> a report and the queue advances to the next root. When all roots are
> terminal and none are resumable, the agent idles — the designed signal that
> the user should author new roots.

## 10. Open Questions

Tuning questions, not structural ones. The architecture holds with either
answer to each.

- **Batching evaluation:** when several cards finish during a drain, should
  the root be evaluated once with all results (cheaper, richer) rather than
  once per card? Leaning yes for Evaluate; no for Generate (each minting
  deserves individual attention).
- **Graph-editing protocol:** the agent may discover the graph is missing an
  edge (a failure mode with no column, a needed stage). What is the protocol
  for the agent proposing graph changes back to the user?
- **Root queue policy:** fixed creation order is the default; if a long root
  starves the queue behind it, escape hatches are skip-and-defer, user
  reordering, or (already chosen) yellow roots leaving the queue.
- **Batched transitions:** whether the agent may classify several finished
  cards in one judgment call on high-volume boards.
