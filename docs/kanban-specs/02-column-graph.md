# Spec 02 — Column Graph

The board's shape: columns as nodes, transitions as edges, outcome vs policy
semantics, and edit-time validation. Source: design doc §2, §8 (invariants 2–3).

## 1. Edges

```swift
public enum EdgeDecision: String, Sendable, Codable {
    case deterministic   // outcome maps to destination; agent never judges
    case policy          // agent (or a fixed rule) chooses among legal edges
}

public enum EdgePolicy: String, Sendable, Codable {
    case agent           // agent judgment picks the edge
    case fixed           // rule-based: first matching outcome label
    case counter         // rotate through destinations by traversal count
}

public struct Edge: Sendable, Codable, Identifiable {
    public let id: String                  // `e_<uuid>`
    public let fromColumnID: String
    public let toColumnID: String
    public var decision: EdgeDecision
    public var policy: EdgePolicy?         // policy edges only
    public var outcomeLabel: String?       // deterministic edges: the outcome this edge carries
    public var isAskTheUser: Bool          // the mandatory "ask the user" edge
}
```

- **Outcome edge** (`decision == .deterministic`): `outcomeLabel` is required.
  When a card finishes with an outcome exactly matching a deterministic edge's
  label from its current column, that edge *must* fire — it is a mapping, not
  a choice (design doc §2).
- **Policy edge** (`decision == .policy`): carries a `policy`. The agent is the
  transition function for `.agent` edges; `.fixed` and `.counter` are resolved
  by the engine without an LLM call.
- **Ask-the-user edge**: at most one per column, `isAskTheUser == true`, target
  must be the board's single `humanWait` column. These are always legal —
  invariant 3 in edge form.
- Self-edges (`from == to`) are legal — they are the retry-loop cycle shape
  (design doc §2 allows cycles; budget handles safety, spec 07).

## 2. Graph operations (user-owned)

`BoardGraph` — a stateless helper over `Board.columns`/`edges`:

```swift
public struct BoardGraph: Sendable {
    public func edges(from columnID: String) -> [Edge]
    public func deterministicEdge(from columnID: String, outcome: String) -> Edge?
    public func policyEdges(from columnID: String) -> [Edge]
    public func askTheUserEdge(from columnID: String) -> Edge?
    public func entryColumns() -> [Column]
    public func terminalColumns() -> [Column]
    public func validate() -> [GraphViolation]     // §4
}
```

`Edge` list is stored **inside the board document** (spec 03) — the graph is
board data, not engine configuration, because the user edits it at any time.

## 3. Editing protocol (user)

All edits go through typed `BoardGraphEdit` values applied by the daemon —
never raw document writes:

```swift
public enum BoardGraphEdit: Sendable {
    case addColumn(Column)
    case removeColumn(id: String)              // refused unless no card occupies it
    case renameColumn(id: String, name: String)
    case setKind(id: String, kind: ColumnKind)
    case addEdge(Edge)
    case removeEdge(id: String)
}
```

Applying an edit: validate → apply → re-`validate()` → persist with an event.
**Warnings are issued when an edit breaks §4 properties**; hard errors only
for the refusals above. A broken graph does not brick the board — the engine
refuses to *run* (not to load) a board that violates the mandatory-column or
terminal-reachability rules, and reports exactly which paths are dead.

## 4. Validation rules (invariant 2 + 3)

`GraphViolation` cases, each with the offending ids:

1. `orphanColumn` — column unreachable from every entry column (design doc §8.2)
2. `deadEndColumn` — non-terminal column with no outgoing edges, so some path
   cannot reach a terminal column
3. `missingTriage` — no column marked `isTriage`
4. `missingAskTheUser` — some column lacks an ask-the-user edge
5. `terminalWithOutgoing` — terminal column has outgoing edges
6. `danglingEdge` — edge references a nonexistent column
7. `deterministicWithoutLabel` — deterministic edge missing `outcomeLabel`
8. `policyWithLabel` — policy edge carrying an `outcomeLabel`
9. `multipleAskTheUser` — more than one ask-the-user edge from one column

Rule 1–2 are **warnings** on edit (the user may be mid-shape); rules 3–9 are
hard errors. The engine's run loop re-checks 3 and 9 before each root launch.

## 5. Agent graph changes: none

The agent **cannot edit the graph structure** — no proposal channel, no
additive exceptions. If the judge believes an edge/column is missing, its
transition reasoning and the ask-the-user route are the only outlets; the
user then edits the graph themselves. Graph mutation is exclusively the
typed `BoardGraphEdit` path above, invoked by the user.

## 6. Tests

- `BoardGraph` accessors over a fixture graph with fan-out, fan-in, and a
  cycle; deterministic lookup matches only exact outcome labels.
- Each `GraphViolation` fires on a targeted fixture and not on the valid graph.
- Edit application: `removeColumn` refused with a card present; warnings
  surfaced for orphan/dead-end shapes; hard error for `missingTriage`.
- Cycle with a triage re-route: re-entry past budget routes to triage
  (integration with spec 07).
