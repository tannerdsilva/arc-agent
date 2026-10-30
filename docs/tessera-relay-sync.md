# Tessera Relay Sync — Paged Session-Event Loading (design, deferred)

> Saved 2026-10-30 from a design discussion. Status: **proposal, not started.**
> Companion items: `hardening-backlog.md` H3 (session store misses) — the ingest
> barrier below subsumes H3's fix A/B. Two additional backlog candidates from the
> same session: oversized-single-message guard; still-over-budget check
> post-compression.

## Goal

Load session events from tessera incrementally instead of one unbounded fetch:

1. **Session chat events (kind 3001) are paged**: latest X events on open, then
   load the next X when the user scrolls to the cutoff in the web UI.
2. **Everything else loads before chat events count as loaded**: profiles
   (3004), memory (3002), cron (3005), goals (3006), shares (3007), tombstones
   (5), left-notices (3010) — all *replaceable, latest-per-group* records —
   must be complete before any consumer treats a nil read as authoritative.
3. New events keep streaming live; pagination bounds only the initial backfill.

## Current cache layers (as traced 2026-10-30)

- **Relay (server):** LMDB. `queryEventsByDumbFilter` dumps every matching
  event per REQ — why big stores mean slow boots. Query layer already supports
  `since` / `until` / `limit` on filters (`tessera-core/Database/
  ReadOperations/Query.swift:245`); arc just never sends them.
- **Client cache: `ArcModel`** (`TesseraConnection.swift:1044`) — RAM-only,
  keyed by NOSTR event id; `latestByKey` (newest per replaceable d-tag group)
  + `historyByKey`; `pendingRecords` echo-merge for write-read consistency.
  Rebuilt from scratch every process start — nothing persisted client-side.
- **`recordIndex`** — reconciled view over the model used by
  `snapshot(kind:)` / `latestRecord(groupKey:)` / `latestGroups(prefix:)`.
- **Negentropy** is relay↔relay (concord) only; a client reconnect gets the
  full REQ replay regardless.

## Design

### Phase 1 — re-separate what boot awaits

All ten subscriptions are awaited together today; `get()`/restore block behind
that. Split:

- **Await fully (ingest barrier):** meta 3003, profiles 3004, shares 3007,
  tombstones 5, left 3010, cron 3005, goals 3006, memory 3002 — small
  regardless of store size (latest-per-group). Restore only needs meta, so the
  barrier becomes "meta kinds complete" instead of "everything complete".
- **Fetch lazily:** kind-3001 messages, per session, X at a time.

This subsumes H3 fix A/B: the barrier turns the cold-start race
(`ensureStarted` proceeds on partial history after 8s×3 EOSE wait) into a
per-kind deterministic state, and `get()` stops treating "not ingested" as
"does not exist".

### Phase 2 — paged message loading

Two consumers with different needs:

- **Web UI (scroll-up):** open chat → REQ latest X messages of that session →
  scrolling to cutoff fires a follow-up REQ with `until` = oldest-loaded
  timestamp, limit X. Gap: d-tags are `arc/s/<sid>/<seq>` and standard filters
  cannot prefix-match. **Fix: add a small `dTagPrefix` filter option in
  tessera** (relay is ours; ~one function). Alternative (filter by
  application+kind and paginate globally) starves other sessions — avoid.
- **Agent (restore/compression):** engine needs more than the visible tail —
  compression summarizes the middle; the real-token gate reads it. So load the
  latest X eagerly, then **backfill older pages in the background** after turn
  1 is live. Compression summarizes what has arrived; converges as backfill
  completes.

## Gotchas

- **Ordering:** per-writer namespaced records are not comparable by seq — pages
  ordered by `createdAt` with seq tiebreak (same rule as `get()`,
  TesseraSessionStore.swift:192). Page boundaries cut mid-timestamp need the
  same tiebreak, not naive `until`.
- **EOSE semantics change:** with `limit`, EOSE = "this page done", not
  "history done". `EOSETracker` / `initialIngestComplete` must become
  per-kind.
- The 500ms-drain race disappears: a paged fetch blocks its own caller on its
  own page instead of one global sleep.
- **Self-healing republish** in `get()` needs the full messageCount — either
  keep a total count in the meta record (one field) or accept
  count-of-loaded until backfill completes.
- Live subscription unchanged: new 3001 events stream in real time; pagination
  only bounds the initial backfill.
- Optional later: client-side disk cache of `ArcModel` + negentropy-style
  reconcile on boot → instant restarts. Separate project; do after pagination.

## Suggested sequencing

1. Relay `dTagPrefix` filter support + test (tessera).
2. Per-kind ingest barrier in `ensureStarted` (arc; H3 A+B fall out).
3. Paged `fetchMessages(sessionID:limit:before:)` in `TesseraSessionStore`.
4. Web UI scroll-up wiring + agent background backfill.

## Related scenario analysis (same session, 2026-10-30)

- **Minute-long initial fetch:** `ensureStarted` bounds (12 s connect, 8 s × 3
  EOSE) guarantee the partial-history path fires; restore then false-nils and
  turn-end `store.create()` publishes a partial second copy of the session
  (web UI masks it via `initialHistory`; gateway-only sessions lose data).
  Sequence allocation is safe (`takeSequence` reconciles/floors).
- **Context blows over limit mid-turn (huge upload/tool result):** compression
  is best-effort; the ~20K tail is untouchable so an oversized tool result
  survives every compression; anti-thrash throttles; retries replay the same
  oversized payload; recovery only when the giant message ages out of the
  tail. Two backlog candidates: ingestion-time oversize guard (or default
  `prune_tool_results` engine), and a post-compression still-over-budget
  fail-fast with a legible error.
