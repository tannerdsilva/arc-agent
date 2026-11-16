# Spec 05 — Agent Verbs Protocol

How the agent's three acts are elicited, validated, and recorded. Source:
design doc §5. The risk gradient — *transition freely, generate under
budget, evaluate always* — is enforced by different mechanisms per verb.

## 1. The Judge abstraction

All three verbs are decisions; the engine depends on an interface, not the
LLM:

```swift
public protocol KanbanJudge: Sendable {
    /// Verb 1 — classify a finished card along a legal edge.
    func chooseTransition(_ req: TransitionRequest) async throws -> TransitionDecision
    /// Verb 2 — author the next generation of cards.
    func generateChildren(_ req: GenerationRequest) async throws -> [GeneratedChild]
    /// Verb 3 — three-way verdict on the root.
    func evaluateRoot(_ req: EvaluationRequest) async throws -> RootVerdict
}
```

- `LLMKanbanJudge` is the real implementation (one structured-output call per
  verb, prompt built from board state — never the raw document).
- `ScriptedKanbanJudge` is the test double that gates phases 1–3.
- Every judge call embeds: the card, its subtree, the root's
  definition-of-done, the legal edges, the remaining budgets, and (for
  evaluate) the tree's completed results. Context is **composed per call** —
  no hidden transcript dependency.

## 2. Verb 1 — Transition (no gate)

`TransitionRequest { card, result, legalEdges, graph }` →
`TransitionDecision { edgeID, reasoning }`.

Engine-validated order:

1. **Deterministic mapping first**: if the card's `outcome` matches a
   deterministic edge's `outcomeLabel` from the current column, that edge
   fires — `decidedBy: .deterministic`, judge reasoning not even requested.
2. Otherwise, collect policy edges. `.fixed`/`.counter` resolve in the
   engine. `.agent` edges go to the judge, which must return one legal
   `edgeID` + non-empty `reasoning`.
3. **Tie-break**: if the judge returns an illegal edge or multiple genuinely
   match — outcome edges before policy; then any designated fallback column;
   then the judge re-asked once with an explicit tie note; final fallback is
   the ask-the-user edge with the annotated best guess preserved.
4. Provenance (edge, columns, reasoning, `decidedBy`, timestamp) is appended
   to the card; `lastEdgeID`, `columnID`, and `traversalCounts` update
   atomically in the same board revision.

Batched transitions (design doc open question 4): **not in v1** — one
judgment per card. Revisit only for proven high-volume boards.

## 3. Verb 2 — Generate (budgeted)

`GenerationRequest { parentCard, parentResult, root, budgets, graph }` →
`[GeneratedChild]`.

- **Budgets** live on the root: `maxDepth` (default 8 generations), and a
  `mintAllowance` per root (default 25 children). Always-legal exits —
  ask-the-user edge, yellow the root — are outside the budget: the agent is
  never trapped into minting (design doc §5).
- **Child contract validation** (hard, engine-enforced): every generated
  child must carry all three fields, or the generation is rejected and
  re-asked once with the violation named:
  1. `goal` — non-empty and specific.
  2. `input` — `sourceCardID == parentID`, mode declared; reference mode
     requires an artifact id the store can resolve.
  3. `doneCondition` — non-empty.
  No further quality heuristics (word counts, verification methods) —
  deliberately left out; the contract's *shape* is enforced, its *quality*
  is judged by the evaluate verb.
- Lineage stamp is applied by the engine, not the judge: `parentID`,
  `birthEdgeID` (the edge the child is placed along), `generation =
  parent.generation + 1`, and the judge's `whyNext` reason.
- **Placement** — the child enters an `agentWork` or wait column via a legal
  edge from the parent's column; it joins the traversal order at that
  generation point (no scheduling power).
- Depth cap breach does not error: reaching `maxDepth` forces the exhaustion
  evaluation (Verb 3), per the design doc's "forcing function for judgment."

## 4. Verb 3 — Evaluate (mandatory artifacts)

`EvaluationRequest { root, tree, budgets, remaining }` →
`RootVerdict { case continue_; case green(EvidenceChain); case yellow(MissingReport) }`.

- Fires at **every generation point** (after transition, when the engine
  would otherwise pick the next card) and at the **exhaustion point**.
- The judge always judges against the **root's** `definitionOfDone`, never a
  single card's done-condition; the prompt states both and labels them.
- **Green** requires an `EvidenceChain` (spec 06) mapping definition-of-done
  clauses to completed descendant card ids — a green without one is rejected
  and re-asked.
- **Yellow** requires a `MissingReport` (spec 06) — attempts, blocking
  unknown, what the user must provide. Rejected and re-asked without it.
- `.continue_` returns control to traversal/next generation.
- The engine can *force* the yellow path only at exhaustion with no budget —
  the agent cannot be stuck: no viable move *is* an evaluation (design doc
  §5).

## 5. Where the agent sits

v1 shape: the engine runs in the daemon; judge calls are **structured
sub-calls** (a dedicated per-verb prompt through the normal provider stack —
same pattern as the cron aux classifier's first-word verdict parsing). The
board is *not* driven by a free-chatting agent; verbs are constrained
outputs. A conversational mode (chatting *with* the board agent about its
tree) rides later on the same `Judge` surface — noted, not specced.

## 6. Tests

- Deterministic mapping bypasses the judge entirely (spy judge asserts zero
  calls).
- Illegal judge output → tie-break ladder reaches a legal edge every time.
- Contract validation: each violated field rejected; re-ask succeeds; double
  failure produces a structured generation error, not a silent drop.
- Budgets: mint past allowance → forced exhaustion evaluation; depth cap
  ditto; ask-the-user/yellow always legal at zero budget.
- Green without evidence / yellow without report → re-asked; scripted judge
  proves both paths.
