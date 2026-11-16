# Spec 01 — Domain Model

Value types for the board. Everything else in the spec set is defined in terms
of these. Source concepts: design doc §1–§4.

## 1. Board

```swift
public struct Board: Sendable, Codable {
    public let id: String                    // stable slug, e.g. "default"
    public var name: String
    public var lanes: [Lane]                 // structural axis, agent-owned
    public var columns: [Column]             // semantic axis, user-owned
    public var cards: [Card]                 // assembled in memory; persisted as their own records (spec 03 §2)
    public var roots: [Root]                 // §4 roots, one tree each
    public var settings: BoardSettings       // budgets, profile, timeouts
}

/// Per-board configuration. Every field is user-editable (settings dropdown
/// on the board page); the values below are only defaults.
public struct BoardSettings: Sendable, Codable {
    /// Profile the board's agent turns run as (model, provider, skills).
    public var profile: String?              // nil = daemon default
    public var cycleBudget: Int = 3          // re-entries per column per card (spec 07)
    public var maxDepth: Int = 8             // generations from a root (spec 05)
    public var mintAllowance: Int = 25       // children per root (spec 05)
    public var staleMotionTimeout: Duration = .seconds(600)   // spec 07 §4
    public var triageCooldown: Duration = .seconds(300)       // spec 07 §1
}
```

A board is one document; cards carry their position rather than lanes
holding card lists. Rationale: every mutation is a card-level event and the
position is lineage-adjacent state, not container state.

## 2. Lane

```swift
public struct Lane: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
}
```

Purely structural. No kind, no semantics, no ordering constraints beyond
display order. The agent may assign cards to lanes; per design doc §1 lane
assignments are **stable** — lane moves are explicit agent acts recorded in
the card's event log, never side effects of transitions.

## 3. Column

```swift
public enum ColumnKind: String, Sendable, Codable {
    case agentWork      // agent executes the card body here
    case humanWait      // parked until the user releases it
    case timerWait      // releases after a delay or at a time
    case terminal       // absorbing; no outgoing edges
}

public struct Column: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var kind: ColumnKind
    public var isEntry: Bool            // reachable start for new/created cards
    public var isTriage: Bool           // the mandatory triage column (§7 spec)
    public var timerDuration: Duration? // timerWait only
    public var defaultEdgeID: String?   // stale-motion fallback target (§7 spec)
}
```

- Column names are free text; nothing in the engine matches on names.
- `agentWork` columns are where cards execute; every other kind defers or
  ends work. A column with `kind: .terminal` must have zero outgoing edges
  (validated at edit time, spec 02).
- The **"ask the user"** move is *not* a column kind — it is a legal edge from
  every column into the board's single `humanWait` column (spec 02 §4).

## 4. Card

```swift
public enum Readiness: String, Sendable, Codable {
    case runnable
    case waitingOnChildren
    case running
    case done
}

public struct Card: Sendable, Codable, Identifiable {
    public let id: String                       // `c_<uuid>`
    // Position
    public var laneID: String
    public var columnID: String
    public var readiness: Readiness
    // Body
    public var goal: String                     // child contract §5
    public var input: InputPassing?             // child contract §5
    public var doneCondition: String            // child contract §5
    // Lineage (immutable after creation — invariant 5)
    public let parentID: String?                // nil = user-created root-adjacent card
    public let rootID: String                   // every card belongs to exactly one root
    public let birthEdgeID: String?             // edge it was generated along
    public var lastEdgeID: String?              // most recent transition into current column
    public var generation: Int                  // depth from root, for the budget
    // Judgment memory
    public var transitionProvenance: [TransitionRecord]  // per move
    public var traversalCounts: [String: Int]   // columnID -> times re-entered
    // Output
    public var result: CardResult?
    public var attachments: [Attachment]        // raw outputs; body stays readable
}
```

- `parentID == nil` cards are the root's first card (created by the user with
  the root, placed at an entry column). The agent never sets `parentID` to
  nil — the **only-user-creates-roots** invariant lives here.
- `lastEdgeID` is overwritten on each transition; `transitionProvenance`
  accumulates. Fan-in therefore never erases *which* edge brought the card
  here: the last edge is current truth, the provenance list is history.
- `traversalCounts` keys on columnID; the cycle budget (spec 07) reads it.

### InputPassing (output passing, design doc §3)

```swift
public enum InputPassingMode: String, Sendable, Codable {
    case reference   // pointer; child reads output from storage when working
    case summary     // agent-distilled text inlined in the child's input
    case inclusion   // raw copy, small outputs only
}

public struct InputPassing: Sendable, Codable {
    public var mode: InputPassingMode
    public var sourceCardID: String
    public var payload: String   // reference: attachment/record id; summary/inclusion: text
}
```

The mode is **declared on the child**; nothing is silently lost. The engine
never transforms one mode into another.

### CardResult and TransitionRecord

```swift
public struct CardResult: Sendable, Codable {
    public var outcome: String          // free-text classification label
    public var summary: String
    public var producedAt: Date
}

public struct TransitionRecord: Sendable, Codable {
    public let edgeID: String
    public let fromColumnID: String
    public let toColumnID: String
    public let reasoning: String        // required, non-empty
    public let decidedBy: DecidedBy     // .deterministic | .agent | .fallback
    public let at: Date
}
```

## 5. Root

```swift
public enum RootState: String, Sendable, Codable {
    case running
    case green
    case yellow
}

public struct Root: Sendable, Codable, Identifiable {
    public let id: String                       // `r_<uuid>`
    public var title: String
    public var definitionOfDone: String         // the constitution; checkable clauses
    public var state: RootState
    public var firstCardID: String              // the root's original card
    public var evidence: EvidenceChain?         // green only (spec 06)
    public var missingReport: MissingReport?    // yellow only (spec 06)
    public var createdAt: Date
}
```

- A root's **tree** is derived by walking `parentID` links from `firstCardID`
  — trees are never stored as structures. This keeps lineage the single
  source of truth and makes the post-order traversal (spec 04) a pure walk.
- Exactly one root is `running` at a time (design doc §6); the root queue is
  the ordered list of non-terminal roots (spec 04 §3).

## 6. Identity and immutability rules

- `Card.id`, `parentID`, `rootID`, `birthEdgeID`, `generation` are **immutable
  after creation**. Mutation APIs take these as `let` (build a new `Card`
  rather than mutating — enforced by construction, not convention).
- `laneID`, `columnID`, `readiness`, body fields, result, attachments are
  mutable through engine verbs only — never edited directly by the UI.
- Every mutable write appends a board event (spec 03 §3) so the audit trail
  reconstructs any card's history.

## 7. Validation

`Card` and `Board` gain a `validate()` returning typed errors, checked on
every write path:

- card's `columnID`/`laneID` exist; `rootID` exists; `parentID` exists and
  belongs to the same root
- `input != nil` for every card with a parent (child contract is mandatory);
  `input.sourceCardID == parentID` (input comes from the parent's output)
- `timerDuration != nil` iff `kind == .timerWait` (column-level, but validated
  here for the columns referenced by the board document)
- `readiness == .done` implies `result != nil`

## 8. Tests

- Round-trip Codable of every type; decode of legacy-free v1 documents.
- Immutability: attempts to construct a card with altered lineage fields
  compile-fail (API shape test — the fields are `let`).
- `validate()` catches each listed violation with a distinct, nameable error.
- Property test: for any generated board fixture, the parent/child relation
  is acyclic and every card's `rootID` matches its ancestors'.
