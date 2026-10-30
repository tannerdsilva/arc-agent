# Hardening Backlog

Issues found during live testing on 2026-10-29 (compression verification run via the web UI). Each item includes observed evidence, suspected location, and a suggested hardening approach.

---

## H1. Profiles editor save does not persist to the store

**Observed.** Setting "Compress at" to 130048 in the Profiles editor appeared to save (detail view showed the new value), but the profile record in the tessera store kept its old `Updated` timestamp and the field was absent from the stored record. The engine continued to resolve the compression budget from the default ladder (`profile compressionBudget → ARC_COMPRESSION_BUDGET env → 32000`), so the edit had no effect until manually written. An earlier attempt to save `130000` also failed silently — the number input's `step` validation (1024) rejected the value with no visible error or toast.

**Suspected location.** The Profiles editor save handler in `Sources/ArcWebUI/` (form submit path) — either the submit handler returns early on client-side validation without surfacing the reason, or the store write is fired but dropped without awaiting or logging a failure.

**Hardening approach.**

1. Surface every rejected save as an inline validation message next to the field and as a toast; a silent no-op save is the bug, the invalid value is not.
2. Log the store-write result (`[ArcAgentCore] profile save failed: <error>`) so a dropped write is visible in the Logs panel.
3. After a successful write, re-read the record before confirming; the optimistic detail view should not show state the store does not hold.
4. Verify the effective ladder in the chat composer's context-usage tooltip matches the stored value (it currently reads the resolved budget, which is correct — the mismatch is the save, not the tooltip).

---

## H2. Auxiliary models need `extra_body` passthrough (thinking-mode summarizers unusable)

**Observed.** Configuring the compression aux summarizer to a reasoning model (nVIDIA Nemotron-3.5-Lightning, served at a local vLLM endpoint) made every compression run fall back to the extractive record: `compression: aux summary unavailable; using extractive record`. The endpoint is healthy; the model returns an empty `content` plus `reasoning_content` unless the request sends `chat_template_kwargs: {"enable_thinking": false}`. Arc's auxiliary model configuration has no field for extra request-body parameters, so the flag cannot be sent.

**Suspected location.** Auxiliary model request construction in `Sources/ArcAgentCore/` (the aux call path used by `Compression/`).

**Hardening approach.**

1. Add an optional `extra_body` (arbitrary JSON merged into the aux chat-completions request) to the auxiliary model config schema, mirroring the reference agent's behavior.
2. Also treat a response whose `content` is empty but `reasoning_content` is present as a parse failure with a specific log line, rather than a generic "unavailable" — the current message hides the actual cause.
3. Test: configure aux with a thinking model + `extra_body` flag, run compression, confirm `aux summary` succeeds and the extractive fallback does not engage.

---

## H3. Session store misses: `not found in store; starting fresh` on every turn

**Observed.** The Logs panel repeatedly shows `session <UUID> not found in store; starting fresh` for an active chat between turns. The conversation continues via the in-memory transcript, masking the miss. The same UUID is reported missing multiple times, so the session record is not being found (and possibly not being written) on the persistence path.

**Suspected location.** Session resolution/write in the web UI engine (`Sources/ArcWebUI/AppState+Actions.swift` and the session store adapter in `Sources/ArcAgentCore/Storage/`). Related to the previously observed silent write-death on the tessera tunnel.

**Hardening approach.**

1. Distinguish "genuinely new session" from "expected session not found": the latter should log at warning level with the store backend name, and the write path should be probed before the turn proceeds.
2. After a `not found` miss, the subsequent write-back should persist the full transcript so a restart does not lose history; verify by restarting the daemon mid-chat and confirming the transcript survives.
3. Add a store health signal to the Logs panel (last successful session write timestamp) so a persistently dead write path is visible without reading code.

---

## Test evidence (2026-10-29 run)

- Compression fired at the resolved 32000 budget: `compression: running (estimated ~45319 tokens, limit 32000)`.
- Working context shrank 45.3k → 29.0k tokens (usage meter).
- Post-compression quiz answered all three planted facts correctly from the compressed context.
- Retention before compression: 3/3 correct.
- Aux summarizer: fell back to extractive on every attempt (H2).
- Profile save: no-op (H1).
