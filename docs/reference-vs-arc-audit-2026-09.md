# reference ↔ Arc Agent — Capability Audit (Sep 2026)

**Purpose:** complete comparison of the reference agent vs ARC Agent, focused on what
Arc is missing that would improve its **speed** and **response quality**.

**Method (clean-loop audit):** every finding below was verified in BOTH trees —
reference mechanism confirmed in the upstream checkout (pin `9d4ef04e`,
2026-08-05, v0.20+ with 109 tool files, 182 CLI modules, ~252K lines core+tools)
and Arc presence/absence confirmed in `Sources/` (51,376 Swift LOC, 10,198 test
LOC, 607 tests green on `tessera`). Findings were checked, re-checked against the
opposite side, and only items that survived both directions are listed.

## 1. Scale snapshot

| Dimension | reference | Arc |
|---|---|---|
| Agent core | ~252K lines (Python), 312 files | ~51K lines (Swift), 3 targets |
| Tools | ~77 tool names, 33 toolsets | 65 registered (55 core + plugin pkg_*/hex_sum/weather) |
| CLI commands | ~60 (`chat … prompt-size`) | 24 (`chat … mcp`) |
| Tests | 2,669 files / 643K lines | 607 tests / 63 suites |
| Prompt caching | `prompt_caching.py` (4 cache_control breakpoints) | `PromptCachePlan.swift` + Anthropic `cache_control` |
| Context engines | `context_engine.py` + prune-tool-results | `DefaultContextEngine` + `PruneToolResultsEngine` |
| Compression | `context_compressor.py` (head + ~20K tail + LLM summary, anti-thrash) | `MicroCompactor` + `ContextCompression` (reference-shaped) |
| MoA | `moa_loop.py` proposer/aggregator | `MoAService` (lazy, built from `moa` config) |
| Aux tasks | 14 canonical keys | 16 (`goal_judge`, `verification` added) |

## 2. Confirmed at parity (no action)

Prompt-cache markers, cache-tiered system prompt, compression invariants +
anti-thrashing, parallel tool batches with watchdog (`ToolBatchExecutor`),
approval gate + dangerous-command detector, aux model routing (per-task),
credential pool/failover, rate-limit tracker, retry handler, stream patience,
message sanitizer (orphan/surrogate), context engine router, MoA, memory
provider (add/replace/remove/batch + prefetch seam), session_search, web
search/extract, tts/transcription, image/video generation, delegation
(steer/stop/list), cron, kanban core, projects, skill_manage/skills_list,
tool_search, send_message, checkpoints, goals, heartbeat, personality,
deliverable mode, verify-on-stop, tool gateway, context references/scanner,
learning graph/journey CLI, OSV audit CLI, approvals suggest.

## 3. Gaps → impact on speed / responses

### A. Speed levers

| # | Gap | reference mechanism | Arc state | Impact |
|---|---|---|---|---|
| S1 | **Deferred tool registry** | `tools/tool_search.py`: core tools never deferred; tier-1 tools appear in the prompt as a *grouped name+short-desc manifest*; full schemas load via `tool_describe`/`tool_call` | All 65 schemas always in the prompt; `tool_search` exists but there is **no manifest, no `tool_describe`, no `tool_call`** | **Biggest single speed+cost win.** ~65 full schemas ≈ 20–30K prompt tokens vs ≈30 core + manifest. Cuts TTFT, prompt cost, and model distraction per turn. |
| S2 | Skills-index snapshot cache | `prompt_builder._skills_prompt_snapshot.json` + mtime/size manifest | Arc builds `buildSkillsIndex(config.skills)` into the prompt each rebuild (no mtime cache) | Medium. Prompt rebuilds recompute index; a snapshot cache avoids needless rebuild/invalidate churn. |
| S3 | Compression trigger parity | `should_compress_info`: threshold vs `last_prompt_tokens` + cooldown/ineffective reasons surfaced to UI | MicroCompactor runs post-turn; trigger/reason surfacing differs | Low-Medium. Behavior parity mostly there; the *reason* channel (cooldown/ineffective warnings) is missing. |
| S4 | Retry/backoff + reasoning-timeout nuance | `error_classifier.py` (1,841 lines, per-error backoff table), `reasoning_timeouts.py`, `chat_completion_helpers` patience budgets/watchdogs | Arc `RetryHandler`/`CircuitBreaker`/`StalenessPolicy` exist | Low. Verify backoff-equation parity per error class; port gap if any. |
| S5 | Ops/tuning CLIs | `reference prompt-size`, `reference doctor`, `reference status`, `reference backup`, `reference logs` | Arc has none of these as commands | Low but high-usefulness: `prompt-size` (token breakdown per section) makes S1/S3 tunable; `doctor`/`status` speed ops. |

> **Shipped (Sep 28 2026):** S1 + S5 implemented. `arc prompt-size` measures
> **−1,815 tokens/prompt** (8,196 → 6,381; 55 → 38 schemas; manifest 318 tok)
> on the built-in registry. Bridge trio `tool_search`/`tool_describe`/
> `tool_call` (reference tiered disclosure), `tool_search` config
> (`threshold_pct` / `listing_max_tokens` / `listing` / `deferred_toolsets`),
> and `prompt-size [--json]` / `doctor` / `status` are live. CLI-level bridge
> E2E pending credentials (key lives in user env; dispatch path shares the
> tested `dispatchToolCall`).

### B. Response-quality levers

| # | Gap | reference mechanism | Arc state | Impact |
|---|---|---|---|---|
| R1 | **Todo tool** | `tools/todo_tool.py` + "todo hydration" into turn context (`conversation_loop` post-turn hooks) | **Missing** as an agent tool (webui has a todos page; the model cannot read/write its own task list) | **High.** Agent-visible task tracking materially improves multi-step execution and reporting. |
| R2 | **Deferred manifest** (response side) | fewer irrelevant schemas → better tool selection | all schemas always present | High (same work as S1). |
| R3 | `vision_analyze` / `video_analyze` | direct image/video understanding tools | Arc only has `browser_vision` (page screenshots) + `image_generate`/`video_generate` | Medium. Users can't reference local images/video unless via CDP. |
| R4 | **Think-scrubber** | `think_scrubber.StreamingThinkScrubber` — strips Thinking Process preamble from streamed text | **Missing** (no scrubber; relies on adapter behavior) | Medium. Streams can leak reasoning preamble to users; scrubber is cheap to port (stateful tag buffer). |
| R5 | Kanban collaboration verbs | `kanban_comment/link/attach/attach_url/attachments/heartbeat/unblock` | Arc has only `block/complete/create/list/show` | Medium for multi-profile usage. |
| R6 | **Post-turn background review nudges** | `background_review.py` (1,081 lines) + `conversation_loop` post-turn hook (skill/memory review nudges) | **Missing** | Medium. reference quietly reminds the agent of relevant memory/skills after turns; quality compounding over time. |
| R7 | Curator execution surface | `curator.py`/`curator_backup.py` + `reference curator` CLI + scheduled trigger | Arc has `Skills/Curator.swift` (policy/state/prompt — `isDue`, `transitions`, review prompts) but **no `arc curator` command and no trigger wiring** | Medium. Logic done; CLI + cron/gateway trigger completes it (auto skill pruning/archiving keeps skill index lean → smaller prompt). |
| R8 | Verification evidence | `verification_evidence.py`: terminal results carry `{cmd, cwd, exit_code, hash}` | Arc terminal tool shows exit_code/cwd context; no hash/evidence dict | Low. Mostly cosmetic for audits. |
| R9 | LSP integration | `reference lsp` + lsp.md (JSON-RPC stdio client for symbols/diagnostics) | **Not implemented** (deferred from prior batch; largest single item) | Medium for coding-centric sessions. |
| R10 | Queue/dispatch of other agents' runs | reference `queue`/`dispatch` semantics | Not implemented (gateway registry API was approval-blocked during earlier inspection) | Medium for multi-agent ops. |

### C. Explicitly out of scope for Arc (by design — not "missing")

Platform/ecosystem tools and surfaces that conflict with Arc's single-binary,
minimal-dependency, Swift-native posture (they belong in Arc *plugin/adapters*
if ever needed): discord/discord_admin, feishu_*, homeassistant (ha_*),
x_search/xai_video_*, yb_* (Yuanbao), whatsapp/whatsapp-cloud/slack adapters,
computer-use desktop suite (`computer_use`, `focus_pane`, `open_preview`,
`read_preview`, `read_terminal`, `close_terminal`), Nous Portal (`portal`),
secrets/egress (Bitwarden/1Password + iron-proxy), billing/credits/insights
upload, i18n, `pets`/`gui`/`desktop`/`skin`, `update`/`uninstall`, `proxy`.

## 4. Recommended implementation order

1. **S1+R2 — deferred tool registry + `tool_describe`/`tool_call` bridge** (largest speed + response win; `tool_search` already exists → add manifest + 2 tools + registry seam; measurable via new `arc prompt-size`).
2. **R1 — `todo` tool** (small, self-contained, high workflow value).
3. **R4 — think scrubber** (small, streaming parity) and **S2** (skills snapshot cache).
4. **R3 — `vision_analyze`/`video_analyze`** (medium; reuse existing LLM vision plumbing).
5. **R6 — post-turn background nudges** (medium; hook exists at turn end in SessionAgent).
6. **R7 — `arc curator` CLI + wiring** (small; logic complete).
7. **R5 — kanban verbs**, **S3/S4 parity checks**, **R8** (small).
8. **S5 — `arc prompt-size` / `arc doctor` / `arc status`** (small ops polish).
9. **R9/R10** carry-over (LSP, queue/dispatch) — separate focused passes.

## 5. Clean-loop evidence (verbatim greps, both directions)

```
# reference has / Arc lacks
tools/tool_search.py — "_reference_CORE_TOOLS", "deferred" manifest, estimate_tokens_from_schemas
tools/todo_tool.py                       | arc: no todo tool in `arc tools` (65)
agent/think_scrubber.py StreamingThinkScrubber | arc: no "Thinking Process"/scrubber hits
agent/background_review.py + conversation_loop:1480 "skill nudge" | arc: no BackgroundReview
agent/curator.py / reference curator        | arc: Curator.swift exists (policy only), no `arc curator`, no trigger
agent/prompt_builder.py _skills_prompt_snapshot.json + mtime manifest | arc: buildSkillsIndex(no cache)
agent/message_sanitization.py (orphan/thinking/surrogate)  | arc: MessageSanitizer.swift ✓
agent/context_engine.py base + prune_tool_results_only | arc: DefaultContextEngine + PruneToolResultsEngine ✓
agent/prompt_caching.py (4 breakpoints) | arc: PromptCachePlan.swift + AnthropicMessagesClient cache_control ✓
tools/memory_tool.py actions add/replace/remove/batch (no search) | arc: MemoryTool same actions ✓
tools/terminal_tool.py record_terminal_result → verification_evidence | arc: exit_code/cwd shown, no hash evidence
# Arc has / reference has (parity confirmations, both sides present)
max_concurrent tool batch watchdog, retry handler, rate limiter, MoA, aux router, credential pool
```

## 6. Bottom line

Arc is **at parity on the entire conversation-pipeline core** (prompt tiers,
caching, compression, batches, recovery, sanitization, aux routing, MoA,
context engines) and on the high-value feature batch ported in the last two
sessions (projects, skills, goals, heartbeats, checkpoints, blueprints,
personality, context refs, tool gateway, deliverables, verify-on-stop, learning
graph, OSV). The meaningful remaining *speed* gap is **prompt weight from 65
unconditionally-registered tool schemas** (S1 — deferred registry + manifest,
plus its natural S2/R2 companions); the meaningful remaining *response* gaps
are **`todo`, think-scrubber, background-review nudges, vision/video analysis,
kanban verbs, and the curator trigger**. Everything else on the arc cli
surface is either platform-specific (belongs in adapters/plugins) or
operator/UI polish.
