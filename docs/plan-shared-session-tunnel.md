# Shared Session Tunnel — Design Plan

Phase: Vascular Hardening (pre-build design)
Status: **PLANNING — awaiting confirmation on 3 open decisions. No code implemented.**

## Goal

Redesign session sharing so that **only the session owner's machine runs the agent**.
The shared-to user (guest) becomes a **tunnel**: it forwards its own messages into the
session and renders the owner's responses back, running **no agent, no context, no model
config, no tools**.

The tessera relay remains the **sole transport**. There is **no direct connection**
between the two machines. All data flows relay-mediated as signed NOSTR events, pushed to
matching subscription filters.

## Why

The current sharing behavior does **not** do this. Today (`SessionAgent.run()`), a sharee's
instance spawns a *full* `ArcAgent` (resolves model/provider, builds tools, injects SOUL,
constructs context). When the sharee sends a message, `appendMessage` persists it (ACL-gated),
then the code hits the `!SharedSessionACL.isOwner(...)` branch, logs
`"…not the owner; contribution recorded, skipping turn"`, and `continue`s — **the turn is
never run by anyone**. There is no bridge feeding a sharee's relay-published message back
into the owner's turn loop (the owner's `SessionAgent` only reads its own `incomingMessages`
stream). So a contributed message currently just sits in the log.

This design both **fixes that gap** (owner gets woken on a sharee message) and **removes**
the unnecessary full-agent construction on guest machines.

## Architecture

```
OWNER machine (host)                         SHAREE machine (guest / tunnel)
────────────────────                         ──────────────────────────────
full ArcAgent + context                      NO agent, NO model, NO tools
+ tools + SOUL + model                       ┌────────────────────────────┐
┌───────────────────────────────┐            │ relay event subscriber      │
│  wake on sharee message       │◄─────────►│ renders owner transcript    │
│  (relay 3001 → turn input)    │   relay    │ forwards user msg (3001)    │
└───────────────────────────────┘ ────────── │ (no running of turns)       │
        │ streaming deltas ──► kind-3008 ─────────►                        │
        └─ final msg on kind-3001 ──────────►                              │
                                            └────────────────────────────┘
```

Transport semantics (confirmed with user):
- **No direct link.** Every byte goes to the relay and out via a subscription. Neither side
  ever addresses the other's machine directly.
- **Live streaming = NOSTR filter-push.** The owner signs a new event (message or delta);
  the relay fans it out to every connected client whose subscription filter matches
  (application + kind + session tag). "Live" = near-real-time fan-out on publish.
- **Offline-safe.** Relay persists signed events in LMDB. If the owner (or guest) is offline,
  messages queue in the store; on reconnect the subscription re-syncs history and processes
  in order.
- **Roles persist.** Role is encoded in durable kind-3007 share-grant events on the relay;
  `SharedSessionACL` derives role from the newest grant for `(sessionID, owner)` naming the
  pubkey. Roles survive disconnects.

## Pieces to build

### 1 — Role-aware host/guest mode
Branch in `SessionAgent` / `SessionRegistry.getOrCreate` on
`SharedSessionACL.isOwner(identity, owner)`:
- **Host** (owner): current full-agent behavior, unchanged.
- **Guest** (read/contribute): a new lightweight `TunnelSession` that constructs **no**
  `ArcAgent` — only an event subscriber.

### 2 — Sharee → Owner wake-up
Owner's `SessionAgent` subscribes to the session's relay 3001 events; when a
**non-owner-authored** user message arrives, inject it as an incoming turn. This is the
currently-missing bridge that makes `contribute` produce a response.

### 3 — Owner → Sharee streaming
Owner's text deltas published as relay events; final assistant message stays the durable
kind-3001 event. Guest subscriber renders deltas incrementally.

### 4 — Guest web-UI tunnel view
`AppState` opens a shared session in "tunnel view": subscribe to owner stream, render live
deltas, allow send (role ≥ `contribute`), disable owner-only controls. Reads/writes flow
through `SessionStore.get` / `appendMessage` with ACL.

### 5 — ACL & safety (unchanged)
Grants remain pubkey-based (kind-3007). Guest mode only activates with a valid grant.
`appendMessage` still gates `role ≥ contribute`. Read-only grantees get transcript without send.

## Open decisions (awaiting confirmation)

| # | Decision | Recommendation |
|---|---|---|
| 1 | **Replace, not coexist** — drop the current per-side-agent model; owner is sole host. No parallel "both sides independently drive" mode. | Replace it. |
| 2 | **Streaming delta kind** — separate kind (3008) for live deltas; final message on 3001. Keeps transient fragments out of durable history. | Separate kind. |
| 3 | **Roles** — keep both `read` (view-only) and `contribute` (can send). | Keep both. |

## Not changed by this design
Model/provider config resolution, tool execution, SOUL, context assembly, Compactor,
standing goals, memory — all remain **on the owner's machine only**.

## Phasing (each independently commit-able)
- **Phase 1** — Role-aware host/guest mode split (guest = no agent) + tests.
- **Phase 2** — Sharee→owner wake bridge (fixes the no-response gap) + tests.
- **Phase 3** — Owner→guest streaming deltas + tests.
- **Phase 4** — Guest web-UI tunnel view + share-panel polish.

## Test & observability
- Pure `SharedSessionACL` role tests (already exist; extend for host/guest mode).
- Host vs guest mode tests; wake-bridge tests; delta-stream tests.
- Logging distinguishes host (`session: host running turn`) vs guest (`session: guest tunnel`)
  modes.
