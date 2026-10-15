# arc-agent — Fix Plan for Benchmark Findings (F1–F4)

Companion to `docs/benchmark-hermes-vs-arc-2026-10-06.md`. Code-verified against the working tree (`tessera`). Scope/effort marks: S small, M medium, L large.

---

## F1 — P0: Implement real delegation (currently a stub)

### Root cause
`Sources/ArcAgentCore/Delegation/DelegationManager.swift:82-86`:
```swift
let task = Task { [weak self] in
    // Simulate work — in production this would call the LLM
    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s placeholder
    await self?.complete(id: id, summary: "Completed: \(goal.prefix(80))")
}
```
`steer()` (line 105-107) logs the steer message into `summary` instead of delivering it. `DelegateTaskTool.swift:53-77` polls the manager for ≤60s and returns the summary string. Nothing spawns a real agent, nothing calls an LLM, no tools.

### Design (mirrors Hermes `tools/delegate_tool.py` semantics)
- **Child engine = a fresh `ArcAgent`** running in an isolated `Task` (First Law compliant; no threads). It uses the same proven machinery: turn loop, tool dispatch, retries, guardrails — no bespoke mini-loop.
- **Child `Configuration` overrides from the parent:**
  - `model/provider/baseURL/apiKey/auxiliary` — inherited (same LLM client family; child may create its own `HTTPClient(eventLoopGroupProvider: .singleton)` since the parent's client is process-internal; sharing the parent's `httpClient` is also fine once it's exposed — see below).
  - `registry` — the parent's registry; `disabledToolsets` set to `allToolsets − allowedToolsets − {delegation}`.
  - **Semantics change (documented tweak):** empty `allowedToolsets` currently means "child has no tools" (per the tool doc). Change to **"inherit all parent toolsets"** minus the always-blocked set, matching Hermes (children get the parent's toolsets; `DELEGATE_BLOCKED_TOOLS` strips `delegate_task` so there is **no recursive delegation** — which also makes `maxSpawnDepth` a natural depth cap).
  - `maxIterations` — new `DelegationConfig.maxTurns` (default 25) or reuse `config.maxIterations`; child turns are bounded.
  - `sessionStore` — a new **`VolatileSessionStore`** (in-memory, no disk) so the child's transcript is inspectable but never pollutes the parent's store; `persistSessions = false`.
  - `memoryProvider = nil`, `skills = []`, `query = goal` (focused prompt = goal + context — child gets **no parent history**, like Hermes).
  - `platformHint = "delegation"` (logging/hook provenance).
- **Lifecycle:** `spawn()` creates `Subagent` (`.running`), starts the child Task, and stores its handle. On completion the child's **final answer** becomes `Subagent.summary` (the honest parity behavior: the parent reports what the child actually produced). Failures → `.failed` + `errorMessage` (visible in the poll result, no 80-char fake).
- **Steering (real):** the child agent gets an `AsyncStream<String>` steering channel; a public `injectSteer(_:)` on ArcAgent enqueues into `pendingSteers` (the mechanism the REPL already uses). `steer(id:message:)` forwards; child loop drains between iterations.
- **Cancellation:** `Task.cancel()` + the agent loop already checks `Task.isCancelled` at iteration boundaries (verify + add if missing for the streaming variant).
- **Result delivery:** keep the existing poll in `DelegateTaskTool` but raise the cap to config-driven `delegation.timeout` (default 300s) and surface `summary` verbatim. Better: replace polling with an awaited `AsyncStream<SubagentStatus>` per child (the manager emits on complete/fail). Either is fine; streaming is cleaner and removes the 60s ceiling.

### Files
- `Delegation/DelegationManager.swift` — replace stub Task with real spawn; add `AsyncStream` result channel; wire steer channel; honor `maxConcurrentChildren` (already).
- New `Delegation/SubagentRunner.swift` (or inside the manager) — builds the child `Configuration` + child `ArcAgent`, runs it, captures final text, calls `complete/fail`.
- New `Session/VolatileSessionStore.swift` — in-memory `SessionStore` (also reusable by tests today).
- `Tools/DelegateTaskTool.swift` — await per-child result stream; update description (empty toolsets = inherit; note no recursive delegation).
- `Agent/ArcAgent.swift` — `injectSteer(_:)` if not already public; expose `httpClient` for sharing (optional).
- `Config/ArcConfig.swift` — extend `DelegationConfig` with `maxTurns` (25) + `defaultTimeout` (300); wire `maxConcurrentChildren` (already wired? verify `ArcAgent.run()` initializes `DelegationManager` with it).
- `Agent/ArcAgent.swift` — build `DelegateTaskTool.manager` with `DelegationConfig` values + pass the parent config to the runner.

### Tests (Swift Testing; use the existing mock-LLM seam)
1. Child runs a `terminal`-only flow: goal `echo delegated-echo-42`; mock LLM returns a tool call then a final text; assert `summary == "delegated-echo-42"` (the exact failure mode the benchmark caught).
2. Toolset filtering: child with `allowedToolsets: []` may call `terminal` but **not** `delegate_task` (assert schema absence).
3. Steering: mock LLM blocks on a tool call; `steer()` arrives; loop drains it; final summary reflects the steer.
4. Cancel: mid-run cancel → `.cancelled` + task handle released.
5. Cap: `maxConcurrentChildren = 1` → second spawn throws `tooManyChildren`.
6. `VolatileSessionStore` round-trip unit test.
7. Live verification (post-build): re-run benchmark prompt 5 against the local model — parent must report the child's real `delegated-pong-42`.

### Effort: L (the flagship). Risks: child config cloning (forgetting a field like `reasoningEffort`), LLM-client sharing/HTTPClient lifecycle, steer-loop integration. Mitigate with the full test list above.

---

## F2 — P2: Web-fetch fabrication (example.com `<h1>`)

### Root cause
`WebExtractTool` returns cleaned page *text* (`stripHTML`). The model filled in a page-structure detail (`<h1>Example Domain</h1>`) that was **not** in the tool output (live page has no `<h1>`; Hermes-verified via browser DOM). The no-fabrication guidance exists but web claims aren't grounded in a verbatim snippet.

### Fix (small, two parts)
1. **Grounding envelope** in `WebExtractTool.extract(...)`: prepend a structured metadata block per page:
   ```
   ### <url>
   [TITLE] <title text or (none)>
   [H1] <first h1 text or (none)>
   [LENGTH] <chars>
   ---
   <content>
   ```
   `stripHTML`-based fallback: report headings by extracting `<title>/<h1>..<h6>` via regex **up front** (before whole-body stripping) and mark them `(none)` when absent. Backend providers (Firecrawl/Exa) already return markdown — derive the envelope from their metadata when present.
2. **Tool description + guidance:** add to the tool description: *"Report only the elements actually present in the output; never assert page structure (headings, links, titles) that the returned text does not contain."* Consider one line in the system-prompt tool-fidelity guidance (alongside the existing no-fabrication block).

### Tests
- Unit: `stripHTML` + envelope on fixture HTML with `<h1>` and without → correct `[H1]`/`(none)`; markdown backend path derives envelope.
- Live: prompt 11 re-run on the local model — the answer must not claim an h1.

### Effort: S

---

## F3 — P1: Session plumbing (two gaps)

### 3a — `arc chat -q` never persists
**Root cause:** `-q` mode streams via `streamConversation` (`Arc.swift:293` → `ArcAgent.streamTurn` → `runStreamingTurnLoop`), which never calls `persistConversationIfNeeded()` (only `runConversation`'s loop does, `ArcAgent.swift:1046`).

**Fix:** after the main iteration loop in `runStreamingTurnLoop` (all normal-term paths: `.completed`, max-iterations, interrupted, error), call `await persistConversationIfNeeded()` — same guard (`persistSessions` + watermark) makes it a no-op for interactive/webui paths, and enables persistence for `arc chat -q`, daemon streaming, and webui streaming uniformly.

**Tests:** agent with `persistSessions: true` + mock store + mock LLM; call `streamConversation(...)`; assert `store.create`/`appendMessage` called and session content includes the tool messages. Also a CLI-level smoke: `arc chat -q "x"` (file-store config) → `arc sessions list` shows a new session.

### 3b — Session admin commands hardcode `FileSessionStore`
**Root cause:** `Sources/arc-agent/AdminCommands.swift` instantiates `FileSessionStore()` at lines 37, 75, 114, 389, 452, 491, while the chat path resolves tessera vs file in `Arc.swift:195-212`. Any tessera-persisted session is invisible to `sessions list/show/delete/export/rename`.

**Fix:** extract the chat-path resolution into a reusable factory, e.g. `ArcStorage.makeSessionStore(arcConfig:) async throws -> SessionStore` (same `tessera` + `healthCheck()` logic, same fallbacks), used by:
- `Arc.swift` (chat) — replacing its inline logic,
- `AdminCommands.swift` sessions commands (6 sites) — plus `approvals`/`knowledge`/`ops` commands if they use third stores,
- `ArcDaemon.swift` if it resolves the store separately (check; if it does, route through the same factory).

**Tests:** unit — config without `tessera` → `FileSessionStore`; config with `tessera` → `TesseraSessionStore` returned (wrap the health check behind an injectable predicate so the test needs no live relay; the two existing env-gated tests cover the live path). Then live: run chat with tessera config → `arc sessions list` shows the live session.

### Effort: S–M (factory + 6 call sites + tests)

---

## F4 — P2: Per-tool-call metadata (corrected scope)

### Finding (corrected)
The store **already** persists structured records (26 assistant `toolCalls` w/ args + 33 `.tool` results with `name`/`toolCallID`/content — verified in the exported session). Remaining gaps vs Hermes `state.db` rows: **no effect classification** (`effect_disposition`) and **no per-tool latency**.

### Fix (small)
- `LLM/Message.swift`: add optional `toolDisposition: String?` and `toolDuration: Double?` (tolerant `decodeIfPresent` — no breakage for stored sessions).
- Tool executor path in `ArcAgent` (where `.tool` messages are appended, ~lines 1742/2099/2606/2661): stamp `timeIntervalSince` metrics + classify via the existing `ToolGuardrails` verdict (`allowed/approval/denied/destructive` — map to a disposition string; the guardrails already decide this, so the classification is free).
- Expose in `sessions export` JSONL (already encodes codable messages).

**Tests:** Codable round-trip including new fields (nil-backward-compat), and one assertion that a `.tool` message carries `toolDisposition` after a guarded execution.

### Effort: S

---

## Sequencing

| Step | Item | Size | Rationale |
|---|---|---|---|
| 1 | F3a (`-q` persist) + F3b (store factory) | S–M | Small, unblocks automation + live verification, low risk |
| 2 | F2 (web envelope + guidance) | S | Small, closes the one fabrication seen in the wild |
| 3 | F4 (tool metadata) | S | Tiny; improves observability parity |
| 4 | F1 (real delegation) | L | Flagship; build last but on top of the store/registry seams |
| 5 | Re-run benchmark prompts 2, 5, 11, 14 on the local model + full suite `swift test` | — | Prove each fix; keep suite green (currently 878 tests / 95 suites) |

Each step: `swift build` → new tests green → commit (per repo rule; never push).

## Verification (after F1)
Re-run benchmark prompt 5 (delegation) and prompt 11 (web) against the identical local model; artifact-level checks same as the benchmark. Confirmation criteria:
- p05: parent summary contains the child's literal `delegated-pong-42`.
- p11: no fabricated `<h1>`.
- `arc chat -q "hi"` + `arc sessions list` shows the new session; `rename`/`export` work on it.
- `swift test` all green; no new warnings.
