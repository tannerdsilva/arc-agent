# Spec 07 — Invariants Layer

The layer below user and agent; neither can override it. Source: design doc §8.
Each invariant names its enforcement point and its failure mode.

## 1. Cycle budgets (invariant 1)

- `Card.traversalCounts[columnID]` increments on every entry into a column
  (spec 01 §4).
- Board setting `cycleBudget: Int` (default 3, user-editable — spec 01
  `BoardSettings`). Exceeding it **forces routing to the board's triage
  column** via a synthesized transition: `decidedBy: .fallback`, reasoning
  "cycle budget exceeded for column X."
- **Reset rule**: a count resets *only* on genuine progress — the card's
  `result` changes (new output produced), or the subtree below it advanced
  (a descendant transitioned into a column it had never been in). Re-entry
  itself never resets (the amnesia that lets loops run unbounded).
- **Triage retries**: a card in the triage column is re-run automatically
  after `triageCooldown` (default 5 min, user-editable). The retry produces
  a fresh `CardResult`, which re-enters the normal transition path — the
  judge classifies the new outcome along legal edges like any other result.
  The cycle budget still applies: a retried card that re-enters the same
  over-budget column routes back to triage, and the loop is bounded by the
  fact that each retry *must* produce a new result before it can leave
  (a result identical to the previous one keeps the card in triage and the
  cooldown re-arms — no unbounded spin, the engine logs each cycle).

## 2. Graph validation on edit (invariant 2)

Specified fully in spec 02 §4 — this spec only fixes the *engine* side: the
run loop re-checks hard rules (3, 9 of spec 02) before each root launch and
**refuses to run** a board violating them, reporting the exact violations.
Warnings (orphan/dead-end) never block running; they surface in the web UI
and the engine log.

## 3. Mandatory columns and the ask-the-user move (invariant 3)

- Exactly one `isTriage` column per board; every column has an
  ask-the-user edge into the single `humanWait` column. Enforced as hard
  graph rules (spec 02 §4 rules 3, 4, 9) — creation-time defaults seed a
  new board with triage + humanWait so a valid board is the default shape,
  not a chore.
- "Ask the user" is a **legal move from everywhere**, including inside
  Verb 2 placement and the tie-break ladder (spec 05 §2 step 3). Asking
  routes the *card* to `humanWait`; the root's queue position is preserved;
  the user releases the card from the web UI and traversal continues.

## 4. Stale-motion fallback (invariant 4)

Specified in spec 04 §6 — this spec fixes the contract: the fallback moves
cards along `Column.defaultEdgeID` after `staleMotionTimeout` **only** when
the judge is unreachable (provider errors classified as unavailable — same
error taxonomy as the LLM client's retry layer). A judge that *answers*
badly is not "unavailable"; that is the tie-break ladder's job. Every
fallback move stamps `decidedBy: .fallback` with the timeout reason, and a
fallback move **consumes no budget** but *does* increment traversal counts
(cycles still tracked).

## 5. Lineage immutability (invariant 5)

Enforced by type shape (spec 01 §6: `let` fields) and by the store: cards
are written only by the engine through the daemon (single-writer, spec 04
§1), and the engine has no code path that mutates
`parentID`/`birthEdgeID`/`generation` after creation. Lane reshuffles touch
`laneID` only; merges (fan-in) touch `columnID` + `lastEdgeID` + provenance
append only. The append-only event log (spec 03 §2) is the historical
record; no replay-diff audit is built on top of it.

## 6. Only the user creates roots (invariant 6)

- The engine exposes `createRoot` on the **user-facing surfaces only** (CLI,
  web UI, daemon HTTP). The agent surfaces (judge protocol, agent tools) have
  no root-creation call — by API shape, not by policy text (spec 05 §1 has
  no such method).
- Verb 2 creates cards **with** `parentID` always set; a generated child with
  `parentID == nil` is a validation error.

## 7. Tests

- Cycle budget: re-enter a column 4× → routed to triage with fallback
  provenance; new result → count reset; re-entry alone → no reset.
- Triage retry: card routes to triage, cooldown elapses, re-run produces a
  new result and re-enters transition; identical result keeps it in triage
  with the cooldown re-armed; budget still enforced.
- Fallback vs judge-answer distinction: provider timeout triggers fallback;
  judge returning an illegal edge triggers tie-break, not fallback.
- API-shape test: no root-creation method on `KanbanJudge` or agent tools.
