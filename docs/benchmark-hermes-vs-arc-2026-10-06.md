# Hermes Agent vs arc-agent — Technical Benchmark Report

**Date:** 2026-10-06
**Harness pins:** Hermes Agent v0.20.0 (2026.8.3) @ `9d4ef04e` · arc-agent @ `0025bf9b` (tessera branch, prompt-guidance commit)
**Sessions:** Hermes `20261006_190807_200313` / arc `E7354C9E-8B28-4AB3-9350-1A1C5F3A4920`, both titled **BENCHMARK TEST**

---

## 1. Methodology

Both harnesses were driven via their CLIs, one at a time, against a **single identical 17-prompt suite** (`/tmp/bench-suite.jsonl`, one JSON prompt per line, byte-identical text for both agents). Every prompt targeted a distinct surface: formatting, file R/W/search/patch, terminal, blocked-path honesty, delegation, skills, memory, session search, progressive tool disclosure, code execution, error recovery, planning, git, parallel batching, long-context precision, cross-turn recall, and meta-introspection.

**Model caveat (important):** the normal benchmark model box (deepseek-v4-flash-vision-exp, served by oMLX at `[fdfd:a87e:…]:8888` via the WireGuard tunnel to a Raspberry Pi) was **offline** for the entire run (no ARP/ICMP/SSH; LAN IP unreachable). Both agents were re-pointed at the **same local oMLX server on this Mac** (`127.0.0.1:8000`) serving **Qwen3.6-35B-A3B-OptiQ-4bit** (262k context) for the whole suite — so the comparison stays apples-to-apples on model, but is not the usual flash model. Configs were backed up before and restored after (arc `~/.arc/config.json`, hermes `~/.hermes/config.yaml` — both verified restored; daemon never restarted and remains on its in-memory tessera config, HTTP 200).

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

## 3. Timing (same model, wall clock)

| | arc-agent | hermes-agent |
|---|---|---|
| Total | 866.4 s (14.4 min) | 594.2 s (9.9 min) |
| Mean / prompt | 50.9 s | 35.0 s |
| Median | 40.7 s | 27.4 s |
| Fastest / slowest | 17.0 / 105.2 s | 14.2 / 68.1 s |

Hermes was **~31% faster on the same model** despite doing *more* real work (real sub-agent, real DB search, browser-based fetch). Arc's interactive-REPL overhead, extra verification passes, and heavier tool surface contribute.

## 4. Tool coverage

**arc (15 distinct, self-reported + artifact-verified):** `terminal, write_file, read_file, patch, search_files, skills_list, skill_view, delegate_task, memory, session_search, tool_search, tool_describe, execute_code, web_extract, todo` — all succeeded except the delegation path (stub).

**hermes (16 distinct, 45 structured tool messages from state.db):** `terminal ×8, write_file ×6, read_file ×6, session_search ×4, tool_search ×3, browser_console ×3, todo ×3, search_files ×2, skills_list ×2, memory ×2, patch, delegate_task, skill_view, execute_code, browser_navigate, browser_snapshot` — all succeeded.

Notable: Hermes used **browser_*** for the web fetch (3 calls) — heavier than arc's single `web_extract`; arc's web tooling is leaner but produced a fabrication in that same prompt. arc session-store data contains **no structured tool-call records** (see F4) — its tool stats are only recoverable from the model's own narration + artifacts.

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

### F4 — Store has no structured tool-call records (P1, observability)
The arc session store persists only the model's text segments (interactive); tool names/results are not recorded as first-class message records (evidence blocks appear only for some tools, e.g. terminal errors). Consequently: transcripts can't be mined for tool stats, token/tool accounting is lost, and replay/audit is weaker. Hermes `state.db` records role, `tool_name`, plus per-session usage counters per message. Recommendation: persist tool-call records (name, args, status, duration) as structured messages in the session store.

### F5 — Session metadata records the creation-time model, not the run model (P2)
Both harnesses did this (arc p17: "deepseek-v4-flash-vision-exp"; hermes p17 uses the same metadata while actually running Qwen3.6-35B) — but arc's answer **trusted** the metadata. Minor; worth a `model_override` field or runtime value in `/status`.

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
