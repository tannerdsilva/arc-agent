# Hermes Agent vs arc-agent — Technical Benchmark Report

**Date:** 2026-10-06
**Harness pins:** Hermes Agent v0.20.0 (2026.8.3) @ `9d4ef04e` · arc-agent @ `0025bf9b` (tessera branch, prompt-guidance commit)
**Sessions:** Hermes `20261006_190807_200313` / arc `E7354C9E-8B28-4AB3-9350-1A1C5F3A4920`, both titled **BENCHMARK TEST**

---

## 1. Methodology

Both harnesses were driven via their CLIs, one at a time, against a **single identical 17-prompt suite** (`/tmp/bench-suite.jsonl`, one JSON prompt per line, byte-identical text for both agents). Every prompt targeted a distinct surface: formatting, file R/W/search/patch, terminal, blocked-path honesty, delegation, skills, memory, session search, progressive tool disclosure, code execution, error recovery, planning, git, parallel batching, long-context precision, cross-turn recall, and meta-introspection.

**Model caveat (IMPORTANT — discovered post-run, see §3):** the comparison was **NOT** model-identical. The normal benchmark model box (`[fdfd:a87e:5fad:9b12:ea5d:b134:3a21:dd1b]:8888`, the tessera/WG peer serving `deepseek-v4-flash-vision-exp`) was briefly unreachable during setup, so Hermes was pointed at a **local oMLX on this Mac (`127.0.0.1:8000`, Qwen3.6-35B-A3B-OptiQ-4bit)** and stayed there. arc-agent, however, never actually used the local server: the profile's local `baseURL` override did not take effect at runtime (empirically proven — ZERO arc requests appear in the local oMLX log; arc's session record and its own p17 answer both correctly identify `deepseek-v4-flash-vision-exp`; every arc CLI run brings up the tessera WG/KCP tunnel). So:

- **arc-agent → deepseek-v4-flash-vision-exp, served remotely through the tessera relay/WG tunnel** (per-prompt process boot + tunnel bring-up + relay round-trips)
- **hermes-agent → Qwen3.6-35B-A3B-OptiQ-4bit, served locally on `127.0.0.1:8000`** (no tunnel; 56 Qwen3.6 completions in the local server log 20:07–20:16 exactly matching per-prompt times)

Every other control (suite bytes, workdirs, yolo, per-prompt timing) is identical as described. This makes the speed comparison *conservative in arc's favor on model speed* — a flash MoE model is typically faster per token than a 35B, and arc still lost on wall time — while clearly attributing the gaps to harness/tunnel factors (see §6). Configs were backed up before and restored after (verified).

- Both runs: `--yolo` (no approval prompts), same workdir pattern (`/tmp/arc-bench`, `/tmp/hermes-bench`), per-prompt wall-clock captured by the runner.
- arc was driven through its **interactive** mode (piped prompt + `/quit`) because `arc chat -q` does not persist sessions (see Finding F3); Hermes through `chat --resume … -q --quiet`.
- Ground truth for scoring = **artifacts on disk** (files created/patched, git repos, counts) plus tool-truth (errors, HTTP status). Every artifact was inspected after the run.

**Setup discovery (arc gaps found while setting up, before scoring):**
- `arc sessions list/show/delete/export/rename` **hardcode `FileSessionStore()`** (`Sources/arc-agent/AdminCommands.swift:37,75,114,389,452,491`), so when the chat path persists to tessera (config present + health check OK), none of the session admin commands can see those sessions. `arc sessions list` showed only stale file-store sessions while today's CLI chats lived in the tessera store.
- **`arc chat -q` never persists at all**: single-query mode streams via `agent.streamConversation(...)` (`Sources/arc-agent/Arc.swift:293`) which bypasses `persistConversationIfNeeded()` (called only in `runConversation`, `ArcAgent.swift:1046`). Verified empirically (no file written even with `--session <id>`). This is why the suite had to be run through interactive mode; it also means the earlier smoke/probe sessions exist only in the tessera store with no CLI-visible title/id.

---

## 2. Results — per prompt

Legend: ✅ pass · ⚠️ pass with caveat · ❌ fail

| # | Surface | arc-agent | hermes-agent | Notes |
|---|---------|-----------|--------------|-------|
| 1 | Format/JSON discipline | ✅ | ✅ | Both: 80-word paragraph + exact `{"name":"bench","count":3}` |
| 2 | File write/read/search/patch/verify | ✅ | ✅ | Both produced `alpha/delta/gamma` after patch; both searched (1 match), verified by re-read |
| 3 | Terminal fidelity | ✅ | ✅ | Both reported `294` (`42*7`) and `ls` verbatim |
| 4 | Blocked-path honesty (missing file) | ✅ | ✅ | **Both** reported the exact error (`cat: /etc/no-such-bench-file-xyz: No such file or directory`, exit 1) and explicitly refused to invent contents. (arc's new TASK_COMPLETION guidance in effect) |
| 5 | Delegation | ❌ | ✅ | **arc's sub-agent output is fabricated-by-stub** — see F1. Hermes ran a real sub-agent and returned the literal `delegated-pong-42` |
| 6 | Skills discovery/load/follow | ✅ | ✅ | Both: `skills_list` → `skill_view('bench-banner')` → exact banner via terminal verbatim. Catalogs differ: arc 93 skills (`~/.arc/skills`), hermes 113 (4 discovery sources) |
| 7 | Memory save | ✅ | ✅ | Both persisted durably: arc `~/.arc/profiles/bench/MEMORY.md`, hermes `~/.hermes/memories/MEMORY.md` — both contain the Mars fact |
| 8 | Session search | ✅ (30s) | ✅ (63s) | arc searched its own session, quoted first prompt/response exactly. Hermes searched the DB, found the **authoring** session (`003b45d575a0`), reasoned about its own first message = `READY` — deeper, correct |
| 9 | Progressive tool disclosure | ⚠️ | ⚠️ | arc: `tool_search` → `tool_describe` → `skills_list` (60-tool catalog). Hermes: `tool_search` correctly notes it only surfaces **deferred** plugin tools (built-ins excluded) — accurate self-diagnosis; both worked |
| 10 | Code execution | ✅ | ✅ | Both: **639** (sum, first 20 primes) via `execute_code` |
| 11 | Error recovery + web fetch | ✅ | ⚠️ | Error handling verboatim on both. **arc fabricated `<h1>Example Domain</h1>`** (F2); Hermes reported "no h1 on the page" — **ground truth (curl live): example.com currently has NO `<h1>`** (title + one `<p>` only). Hermes was correct; arc invented the heading |
| 12 | Planning tracker + scope discipline | ✅ (86s) | ⚠️ (57s) | Both used their tracker (arc `todo`); arc executed exactly steps 1–2, left step 3 pending. **Hermes executed step 3 anyway** (overshoot, self-admitted) |
| 13 | Git | ✅ | ✅ | Both: 2 commits, `git log --oneline` quoted verbatim |
| 14 | Parallel batching | ✅ | ✅ | **Both: all three operations in ONE assistant turn** (three parallel calls) — arc p14 answer confirms Turn 1 for all; hermes same |
| 15 | Long-context precision | ✅ | ✅ | Both generated 100-line doc with `needle here` at 25/50/75; both counted 3 and reported second needle = line **50**; artifacts verified on disk |
| 16 | Cross-turn memory recall | ✅ | ✅ | Both recalled "Mars is teal" + named the `memory` tool (arc: action=add; hermes: action='add' batch) |
| 17 | Meta-introspection | ⚠️ | ✅ | arc: identified arc-agent, tool catalog 60, honest about failures (none), **wrong model name** (echoed session metadata `deepseek-v4-flash-vision-exp` — creation-time metadata; actual run model was Qwen3.6-35B). Hermes: **exact** model + 31 tools listed by name, correct self-diagnosis of `tool_search` scope, no version string (same gap) |

**Totals: arc 16/17 effective (1 delegation fail, 1 fabrication, 1 metadata slip) · hermes 17/17 with 1 scope overshoot and 1 web-truth nuance.**

## 3. Timing (wall clock; arc=remote flash via relay, hermes=local Qwen 35B — see §1)

| | arc-agent | hermes-agent |
|---|---|---|
| Total | 866.4 s (14.4 min) | 594.2 s (9.9 min) |
| Mean / prompt | 50.9 s | 35.0 s |
| Median | 40.7 s | 27.4 s |
| Fastest / slowest | 17.0 / 105.2 s | 14.2 / 68.1 s |

Hermes was **~31% faster overall** despite doing *more* real work (real sub-agent, real DB search, browser-verified fetch) and despite serving a **bigger 35B model locally** (arc was on a flash MoE over a relay tunnel).

## 3.5 Why arc-agent was slower and did less real work

**Slower — ranked contributing factors:**

1. **Remote model through the tessera relay/tunnel (dominant).** Every arc CLI invocation brings up its own WireGuard/KCP interface and tunnels every LLM request through the local relay (`127.0.0.1:51921`) to the WG peer/model box, while Hermes called `127.0.0.1:8000` directly. Observable in every run (WG handshake + `TesseraClient connected` logs) and in the timing shape: the single-call baseline was nearly equal (p01: 17.1 s vs 15.7 s), but arc's deficit grows precisely with tool/multi-call prompts — p15 +78 s, p06 +33 s, p12 +30 s, p17 +30 s, p13 +25 s, p10 +15 s. Each extra round trip on arc carries tunnel setup + relay latency + KCP encode/decode.
2. **Per-run re-boot + full session restore.** arc's interactive mode restored the *entire growing transcript* from the file store at every prompt (18+ messages by p17), re-ran the tool-registry build + plugin scan, and re-sent everything through the tunnel each call. Hermes resumed from `state.db` locally and paid no tunnel for its ~55k-token request (p17: 26 s, with a 55,331-token prompt measured in the local log — served in ~17 s).
3. **Bigger request payloads per call.** arc's schemas surface ~60 tools; Hermes' `tools` array is 31. Combined with #1–#2, every arc call costs more latency per token over the relay.
4. **Per-call cost even with equal call counts (call volume is NOT the driver).** Structured post-run counts: arc 33 calls / 15 tools vs hermes 45 calls / 16 tools. On identical prompts both made the *same* number of calls (p02 5=5, p03 2=2, p06 3=3, p14 3=3, p15 3=3, p13 1=1) — and arc was still 26–78 s slower on them. Even p15, where arc's loop+grep choice is aesthetically worse, had the same call count as hermes' read+search+terminal. The divergence is per-request latency/volume, not round-trip quantity. (The one exception: p11 arc 2 calls vs hermes 6 — the "saving" that produced the fabricated h1.)

**Less real work — ranked contributing factors:**

1. **`delegate_task` is a stub (F1).** The single biggest item: arc produced *zero* real sub-agent work (0.5 s fake + `goal.prefix(80)` summary). Hermes spawned a genuine isolated sub-agent whose literal answer (`delegated-pong-42`) came back. Purely harness-side, independent of model.
2. **Web fidelity over the shortcut.** arc's single `web_extract` + summary layer produced an invented `<h1>`; Hermes' 3 browser calls verified the truth. Precisely the "less work" trade that failed.
3. **Depth of investigation:** arc's session-search was fast but shallow; Hermes' DB search found the *authoring* session and reasoned about provenance, and netted correct, cite-able output for p17 (exact model, 31 tools by name).
4. **Observability of the work itself:** arc's store keeps no structured tool records (F4), so its work is not auditable post-hoc; Hermes' `state.db` records 45 tool messages with names/args. Less recorded work = less *verifiable* work.
5. **Skill universe:** 93 vs 113 skills (arc discovers fewer sources) — a smaller capability surface per prompt.
6. **Scope discipline is a wash:** Hermes overshot (did step 3 unasked); arc respected the boundary. "More real work" ≠ better work here.

**Bottom line:** arc's deficit is architectural, not cleverness: a remote model behind a relay tunnel, heavier per-call payloads, a restore-everything-each-prompt loop, and a stubbed delegation path — while Hermes' speed and work come from local serving, a leaner tool surface, better tool selection, and real sub-agency.

## 4. Tool coverage (structured records — verified post-run)

| | arc-agent | hermes-agent |
|---|---|---|
| Tool calls | **33** | **45** |
| Distinct tools | 15 | 16 |
| Records | `toolCalls` in assistant msgs (26) + `.tool` result msgs (33, with `name`/`toolCallID`/content) | `state.db` rows: `tool_name`, `tool_calls`, `tool_call_id`, `effect_disposition`, `timestamp`, `token_count`, `finish_reason` |

arc: `terminal ×10, write_file ×5, read_file ×3, skills_list ×2, tool_search ×2, todo ×2, search_files ×1, patch ×1, delegate_task ×1, skill_view ×1, memory ×1, session_search ×1, tool_describe ×1, execute_code ×1, web_extract ×1`.

hermes: `terminal ×8, write_file ×6, read_file ×6, session_search ×4, tool_search ×3, browser_console ×3, todo ×3, search_files ×2, skills_list ×2, memory ×2, patch ×1, delegate_task ×1, skill_view ×1, execute_code ×1, browser_navigate ×1, browser_snapshot ×1`.

**Same calls on identical prompts:** p02 both did patch+read×2+search+write (5); p03 both terminal×2; p04 both terminal×1; p06 both 3; p10 both execute_code×1; p13 both terminal×1; p14 both 3; p15 both 3 (arc terminal×2+read, hermes read+search+terminal). **Hermes' extra 12 calls are depth, not noise:** session-search ×4 (arc 1), browser ×5 vs arc's web_extract×1 (p11), planning 8 vs 4 (p12 — where it also overshot), memory ×2, and a post-delegation read_file. Meanwhile p17 arc used terminal+tool_search while hermes answered from memory. **Conclusion: arc did *less* work with *fewer* calls and was still slower → per-call cost, not call volume, is the driver.**

## 5. Findings for arc-agent (prioritized)

### F1 — CRITICAL: `delegate_task` is a stub, not a sub-agent  (P0)
`Sources/ArcAgentCore/Delegation/DelegationManager.swift:82-86`:
```swift
let task = Task { [weak self] in
    // Simulate work — in production this would call the LLM
    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s placeholder
    await self?.complete(id: id, summary: "Completed: \(goal.prefix(80))")
}
```
`steer()` (line 107) is likewise "For now, log the steering attempt." `DelegateTaskTool.swift` calls `manager.spawn` directly, so the model-visible tool returns a **fabricated** "Completed: <goal prefix 80>" after 500 ms — no sub-agent is spawned, no tools run, no LLM call. Reproduction: prompt 5 ran twice — identical 80-char truncated summary both times. The parent agent behaved honestly (reported the literal answer, refused to invent `delegated-pong-42`) — but the feature is non-functional. **This is the single largest feature-parity gap between the harnesses.** Hermes runs a genuine isolated sub-agent (own context, own transcript) and returns the actual result in ~same wall time.

### F2 — Behavioral: single-call web detail fabrication (P1)
Prompt 11: arc claimed the h1 was `<h1>Example Domain</h1>`. Verified ground truth (200 OK, live fetch): example.com currently has **no `<h1>`** (just `<title>` + a `<p>`). Hermes reported "no h1" correctly. arc's `web_extract` response + model prior ("the standard example.com heading") smuggled an unverified detail into the final answer — the exact failure mode the no-fabrication guidance targets, still occurring because the summary/paraphrase layer interpolates plausible details. Recommendation: web results should surface verbatim snippets (like the evidence block) that the model is instructed to quote rather than paraphrase.

### F3 — Session persistence + tooling split (P1)
Two related gaps:
1. `arc chat -q` never persists (streaming path bypasses `persistConversationIfNeeded`; `Arc.swift:293` vs `ArcAgent.swift:1046`). Any `-q`-based automation loses transcripts; Hermes `-q` persists to `state.db`.
2. `arc sessions list/show/delete/export/rename` hardcode `FileSessionStore` (`AdminCommands.swift:37,75,114,389,452,491`) — tessera-persisted sessions (the default when `tessera` config is healthy!) are invisible to all session admin commands, and CLI-side renaming/titling of the webui's chats is impossible. For benchmark/dogfood workflows this forced editing configs to fall back to file storage.

### F4 — Correction: tool records ARE persisted; per-call metadata is not (P2, observability)
**Correction (post-analysis):** arc's session store *does* persist structured tool records as first-class messages: 26 assistant messages with `toolCalls` (including serialized `arguments`), matched to 33 `.tool`-role result messages carrying `name`, `toolCallID`, and result content. (The earlier draft assertion that the store kept only text was wrong — the initial transcript parse skipped tool-role rows. The per-prompt cluster analysis also joined only assistant segments.) The genuine remaining gaps vs Hermes `state.db` rows (which carry `tool_name`, `tool_calls`, `tool_call_id`, `effect_disposition`, `timestamp`, `token_count`, `finish_reason`): arc's tool messages lack (a) an **effect classification** (`effect_disposition`: destructive/approval/denied — the column Hermes uses for safety analytics) and (b) **per-tool latency**. arc does store richer text-side metadata than Hermes (`reasoning`, `usage`, `tps`, `turnDuration`, `terminalReason`). Recommendation (small): add optional `toolDisposition`/`toolDuration` fields to `Message` (tolerant decode), populated in the tool-executor path.

### F5 — Session metadata records the creation-time model; arc's answer was actually correct (P2, corrected)
Post-run discovery (§1) proved arc really ran `deepseek-v4-flash-vision-exp` — so arc's p17 answer (deepseek) was **true**, not a metadata slip as originally suspected. The general finding stands, flipped: both harnesses persist the *creation-time* model in the session record (hermes' record says deepseek while it actually ran Qwen3.6-35B via `-m`), and neither refreshes it per message. Hermes' p17 happened to report the runtime model correctly (from live config); arc reported its (accurate) metadata. Recommendation: record actual model per message (or a `model_override` field), so introspection never depends on metadata luck.

### F6 — Tool surface size (P2)
arc exposes ~60 catalogued tools (with deferred `tool_search` on top); Hermes exposes 31 core + deferred. Larger schema = more tokens/turn and more choice collisions; arc's progressive disclosure exists but the initial set is bigger. Not a defect — a tuning consideration.

### F7 — Cosmetic: interactive exit code (P3)
`/quit` ends the REPL but the ServiceGroup wrapper exits 1 ("service finished unexpectedly"). Clean exit = 0. Also version introspection absent in both (`--version` errors on arc; hermes has no in-session version).

### F8 — What arc did RIGHT (relative gains this run)
The guidance port from today (`0025bf9b`: TASK_COMPLETION / PARALLEL_TOOL_CALL / tool-aware guidance) shows direct effect: blocked-path honesty (p4), one-turn parallel batching (p14), verification-backed file work (p2), honest reporting of the broken delegation result (p5) — the exact behaviors that were historically weak on this model family. Keep it; consider also the Hermes `tool_use_enforcement` model list + `steer channel note`.

## 6. Hermes-side observations (as reference)

- **Scope overshoot (p12):** executed step 3 despite "only steps 1 and 2" — self-admitted. Worth a "do exactly what was asked" calibration; arc respected the boundary.
- **Thinking preamble leak:** `--quiet` output includes the model's `Thinking Process` preamble (Qwen3.6 inline form, no `enable_thinking`/strip) — final answers still correct, but noisy in programmatic use. arc's answers were cleaner (it handles/omits the preamble).
- **Web fetch via browser tools** (3 calls) vs arc's single `web_extract` — more faithful (it caught the missing h1), heavier.
- Mature tool record-keeping, real delegation, correct model introspection.

## 7. Recommended arc improvements (priority order)

1. **Implement real delegation** in `DelegationManager` (spawn an actual `ArcAgent`/task loop with terminal+file tools, propagate a true final summary, streaming status, steering via the input stream) + tests that assert the child's literal output reaches the parent. P0.
2. **Fix `-q` persistence** (call `persistConversationIfNeeded` after streaming, or route single-query through `runConversation`). P1.
3. **Make session admin commands store-aware** (resolve `TesseraSessionStore` like the chat path — one factory function). P1.
4. **Structured tool records in the session store** (message-level `tool_name`/status/duration) — unlocks audit, analytics, and this kind of benchmark without hacks. P1.
5. **Web output quoting** (verbatim snippet + "do not add plausible details") and/or a follow-up evidence check. P1 (fabrication risk).
6. **Metadata truth** (`/status` + session record: actual model used, iteration count, tool count). P2.
7. Exit-code cleanups + `--version`. P3.

## 8. Reproducibility

- Suite: `/tmp/bench-suite.jsonl` (17 prompts, JSONL).
- Runner: `/tmp/bench-runner.py` (agent arg: `arc|hermes`); logs `/tmp/bench-logs/<agent>/pNN-*.log` + `timing.jsonl`.
- Transcriptions: `/tmp/transcripts-arc.jsonl`, `/tmp/transcripts-hermes.jsonl`.
- Artifacts: `/tmp/arc-bench/`, `/tmp/hermes-bench/` (bench.md, p/q/p1/p3/merged, gitbench, longdoc.txt).
- Sessions retained: Hermes `20261006_190807_200313`, arc `E7354C9E-8B28-4AB3-9350-1A1C5F3A4920` — both titled BENCHMARK TEST.

---

## 9. Fix status (2026-10-07)

All four headline findings have been fixed in `arc-agent` on the `tessera` branch
(commits `2699c209`, `ba8a54a0`, `0407af76`, + delegation commit):

| Finding | Status | Verification |
|---|---|---|
| F1 delegation stub | **Fixed** | `DelegationManager` now spawns a real isolated `ArcAgent` child (own context, filtered registry, volatile store); `delegate_task` awaits the child's final answer. Live: parent relayed `delegated-pong-42` verbatim. Unit tests: real-summary, toolset stripping, steering, cancel, cap (5 tests). |
| F2 web fabrication | **Fixed** | `web_extract` returns a grounding envelope (`[TITLE]`/`[H1]`/`[LENGTH]`, explicit `(none)`), plus description guidance. Live: example.com reported `[H1] (none)` and the model answered "no heading elements" (previous run invented `<h1>`). 4 new tests. |
| F3 session plumbing | **Fixed** | `runStreamingTurnLoop` persists at every exit (`arc chat -q` no longer skips persistence; verified: new session file with 4 structured messages). `arc sessions list/show/delete/export/prune/rename` now resolve the same store as the chat path via `SessionStoreResolver` (tessera-first with bounded handshake + file fallback). 5 new tests. |
| F4 per-tool metadata | Open | Not implemented in this pass; the store already records tool call/result structure — disposition/duration metadata remains future work. |

An additional root-cause fix landed while closing F3: `ProfileManager.get()` now
overlays `profiles/<name>/config.json` over the index entry (commit `0407af76`).
This was the loading bug that made the benchmark's `--profile bench` model/baseURL
override silently inert — the reason the arc side ran `deepseek-v4-flash-vision-exp`
remotely instead of the local Qwen model (see section 3.5).
