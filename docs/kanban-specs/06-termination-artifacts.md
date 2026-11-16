# Spec 06 — Termination Artifacts

The two required artifacts that make verdicts trustworthy, plus root resume.
Source: design doc §4, §7.

## 1. Evidence chain (green)

```swift
public struct EvidenceChain: Sendable, Codable {
    public struct Entry: Sendable, Codable {
        public var clause: String          // quoted/identified clause of the definition-of-done
        public var cardIDs: [String]       // completed descendants satisfying it
        public var reasoning: String       // why these cards satisfy this clause
    }
    public var entries: [Entry]            // one per definition-of-done clause
    public var evaluatedAt: Date
}
```

- **Required, not optional** — the judge's green verdict is rejected without
  it (spec 05 §4). The engine validates: every clause of the root's
  `definitionOfDone` (split on explicit clause delimiters — numbered/bulleted
  lines — falling back to sentences) appears in at least one entry, and every
  referenced card is `done` and belongs to the root's tree.
- The chain is the review surface: the user reads clause → cards → reasoning
  and trusts or distrusts the green. Green is **closed forever** — resume of
  a green root is refused by the engine.

## 2. Missing report (yellow)

```swift
public struct MissingReport: Sendable, Codable {
    public struct Attempt: Sendable, Codable {
        public var cardID: String
        public var whatWasTried: String
        public var outcome: String
    }
    public var attempts: [Attempt]             // what the tree already did
    public var blockingUnknown: String         // the specific unknown
    public var userMustProvide: UserProvision  // what resolves it
    public var alternativesConsidered: [String]
    public var reportedAt: Date
}

public enum UserProvision: Sendable, Codable {
    case decision(String)      // a choice only the user can make
    case credential(String)    // named credential type, never the secret itself
    case information(String)   // knowledge/URL/doc
    case capability(String)    // a graph edge/column/verb the board lacks
}
```

- **Required** — a yellow without a report is "giving up" and is rejected.
  The engine validates non-empty `attempts` and a concrete
  `userMustProvide`.
- Yellow parks the tree **in place**: no cards move, readiness freezes, the
  full record stays on the board. The root leaves the running queue into the
  "needs user" pile (spec 04 §3).

## 3. Persistence and surface

- Both artifacts live **on the root record** (spec 01 §5) and are written in
  the same board revision as the state flip, so a root is never seen
  `green`/`yellow` without its artifact.
- The web UI renders: green → clause/card table + reasoning; yellow →
  attempts timeline + "what the user must provide" as the call-to-action.
  Both are plain data renders, not markdown blobs.

## 4. Resume (yellow → running)

- `resume(rootID)` is a user verb (root verbs: create, review, resume).
- Engine behavior: validate the root is `yellow`, move it back to the queue
  **head**, set `state = .running`, append a root event; the tree resumes
  with prior results intact — done cards stay done, so the traversal
  continues from the deepest runnable card *not* done. An **optional**
  `resumeContext` (the user's answer to "what I'm providing") is attached to
  the root and injected into the next judge call's evaluation context (the
  agent knows what changed).
- Resume does **not** reset budgets. Traversal counts persist; the cycle
  budget continues from where it froze (amnesia prevention, design doc §8.1).
  A resume that immediately exhausts again produces a fresh yellow report —
  allowed, but `alternativesConsidered` must reference the prior report.

## 5. Tests

- Green validation: clause coverage enforced (missing clause → rejection);
  card references must be done + in-tree.
- Yellow validation: empty attempts or vague provision rejected.
- Atomicity: state flip and artifact are one revision (no artifactless
  terminal root observable).
- Resume: yellow → head of queue, frozen tree intact, budgets not reset,
  resumeContext injected into the next evaluation prompt (scripted judge
  asserts), double-exhaust yellow references the prior report.
- Green root refuses resume.
