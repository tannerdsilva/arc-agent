# Spec 03 — Storage: Tessera

Board, card, graph, and artifact persistence in tessera (signed NOSTR events),
following the `TesseraCronStore` / `TesseraRecordIndex` / `TesseraSessionStore`
patterns. No SQLite anywhere.

## 1. Store protocol

```swift
public protocol KanbanAgentStore: Sendable {
    func saveBoard(_ board: BoardDocument) async throws
    func getBoard(id: String) async throws -> BoardDocument?
    func listBoards() async throws -> [BoardDocument]
    func saveCard(boardID: String, _ card: Card) async throws
    func cards(boardID: String) async throws -> [Card]
    func appendEvent(boardID: String, _ event: BoardEvent) async throws
    func events(boardID: String, after seq: Int, limit: Int) async throws -> [BoardEvent]
    func artifact(id: String) async throws -> Data?       // attachments, by reference
    func storeArtifact(id: String, _ data: Data) async throws
}
```

`BoardDocument` holds the graph (columns + edges), lanes, roots, board
settings, plus `schemaVersion` and `revision: Int`. Cards are separate
records (§2) with their own `revision`. Every save of a record checks the
revision it read still matches before persisting (stale-writer detection —
the claimEpoch idea from the earlier port plan, renamed).

## 2. Record kinds and dTags

New arc kinds (registered alongside the cron kinds, <40,000 range):

| Kind | dTag | Payload | Resolution |
|------|------|---------|------------|
| kanban-board | `arc/kb/board/<slug>` | `BoardDocument` JSON (graph, lanes, roots, settings) | latest wins |
| kanban-card | `arc/kb/board/<slug>/card/<cardID>` | `Card` JSON | latest wins |
| kanban-event | `arc/kb/evt/<slug>/<seq>` | `BoardEvent` JSON | monotonic seq, append-only |
| kanban-artifact | `arc/kb/art/<slug>/<uuid>` | raw bytes | by id |

- **Cards are their own records** (`arc/kb/board/<slug>/card/<cardID>`,
  replace-on-write). The board document holds the **graph** (columns + edges),
  **lanes**, **roots** (small records: state, artifacts), and board **settings**;
  it does *not* embed cards. Card position lives on the card record. Listing a
  board's cards = one fetch of the card-record prefix for the slug (the same
  indexed-prefix read cron run history already uses). Lineage and
  `traversalCounts` ride the card record; the event log remains the audit
  trail for *every* mutation.
- **Events** record transitions, generations, evaluations, lane moves, graph
  edits, root state changes, artifact additions. Append-only, seq = previous
  + 1.
- **Artifacts** are the `reference` mode targets of `InputPassing` and card
  attachments (diffs, logs, dumps). Stored as their own records so the board
  document stays under event-size limits.

## 3. The actor

```swift
public actor TesseraKanbanAgentStore: KanbanAgentStore { ... }
```

- Mirrors `TesseraCronStore`: `ensureLoaded()` hydration on first touch,
  `TesseraRecordIndex` for in-memory lookup, dTag helpers as static funcs.
- Revision check inside `saveBoard`: re-read the latest record; if its
  revision exceeds the caller's base, throw `KanbanStoreError.revisionConflict`.
  The engine (single-writer via the daemon, spec 04 §1) treats that as a bug;
  the web UI treats it as a reload-and-retry.
- Board events are written in the same `scribe` batch as the board save that
  produced them, so an event and its resulting document state cannot diverge
  by crash order (last-writer-wins on the document; events monotonically
  survive regardless).

## 4. LOCAL fallback

`FileKanbanAgentStore: KanbanAgentStore` — one JSON file per board under
`~/.arc/kanban/<slug>.json` plus `~/.arc/kanban/<slug>.events.jsonl` and an
`artifacts/` directory. Selected by `StoreSelection` exactly like LOCAL cron:
tessera when the relay is reachable, LOCAL otherwise. Both implementations
pass the same conformance suite (§5).

## 5. Tests

- Conformance suite `KanbanAgentStoreTests` parameterized over both stores:
  save/get round-trip, list, revision conflict, event append + pagination,
  artifact store/fetch, delete-board.
- Tessera store: dTag layout stability (golden), hydration after "restart"
  (fresh actor instance reads what the previous wrote), co-tenant isolation
  (application ACL — kanban records ride the per-app membership gate).
- Event/document divergence: kill between event append and save; on next
  load, events still replay to a consistent view (documented tolerance, not
  a crash).
