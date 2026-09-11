# Arc-Agent vs Hermes — Empirical A/B Analysis (2026-09-10/11)

## Methodology

Both agents ran **identical prompts** against the **same model**
(`deepseek-v4-flash-vision-exp`, vLLM, 1M context, keyless) through an
instrumented proxy (`/tmp/ab/proxy.py`, part of the harness, not the repo):

- Per-request capture: status, latency, usage (prompt/completion tokens),
  finish reasons, stream flag, and a wire-shape fingerprint
  (max_tokens, reasoning_effort, system-prompt size, tool count).
- Fault injection: HTTP 429 / 500 / empty 200 on a chosen request index.
- Hermes ran from an isolated `HERMES_HOME` (same config, base_url repointed
  at the proxy; real skills copied). arc ran its real config; for the parity
  runs both were pinned to `reasoning_effort: max` and `max_tokens: 512000`.

## Results

### Cycle 1 — production configs as-is

| cell | Hermes | arc | wall Δ |
|---|---|---|---|
| planning | **TIMEOUT (600s)** — skill-driven tool loop, `plan` skill + terminal | 252s | arc 2.4× faster |
| longctx | 29.2s | 19.2s | arc 1.5× faster |
| toolheavy | 23.5s | 28.2s | ~equal (both correct) |
| toolheavy + 500@2 | 49.5s (recovered) | 39.4s (recovered, logged) | both OK |
| longctx + 429@1 | 27.4s | 21.0s | both OK |
| planning + empty@1 | 397.9s (recovered, nudged) | **0.0s FAILED** | **arc bug** |

### Cycle 2 — parity configs (`effort=max`, `max_tokens=512000`, fixed binary)

| cell | Hermes | arc | notes |
|---|---|---|---|
| planning | 476.4s / 110,470 tok / 62,690 chars | **218.6s / 40,238 tok / 35,182 chars** | arc 2.2× faster, ~2.7× fewer tokens |
| toolheavy | 30.4s / 70,976 tok | 32.2s / 29,057 tok | equal wall; arc 2.4× fewer tokens |
| longctx | 23.7s / 28,880 tok | 19.7s / 17,248 tok | arc faster + cheaper |

Both agents produce correct results in every scenario (file ground truth
verified on disk; longctx answers list all five findings).

### Wire shape (identical prompt, "ok" smoke)

| field | Hermes | arc (after fixes) |
|---|---|---|
| `stream` | true | true |
| `max_tokens` | 512,000 | 512,000 |
| `reasoning_effort` | "max" | "max" |
| `stream_options` | include_usage | include_usage |
| system prompt | 19,328 chars | 6,316 chars |
| tools | 28 | 36 |

## Root-cause inventory (what causes the differences)

1. **Skill library size** — Hermes indexes ~90 skills (incl. `plan`,
   `web_search`, `github-*`); arc indexes 5 (its own `~/.arc/skills`). This
   is the dominant cause: it makes Hermes' planning run a skill-driven tool
   loop (skill_view + terminal writing a plan file) and inflates the system
   prompt by ~13K chars/request (17.1K vs 5.4K prompt tokens). Arc's library
   is purposeful, not a defect.
2. **reasoning_effort** — Hermes sent `max`; arc sent nothing (provider
   default). Fixed: configurable `agent.reasoningEffort` (cycle 2) +
   existential-dispatch bug (cycle 2b) so it actually reaches the wire.
3. **max_tokens** — arc sent nothing (silent vLLM default ~4K cap risk);
   Hermes sends 512,000. Fixed: metadata-driven default + `model.maxOutputTokens`
   override (cycle 1/2).
4. **CLI streaming** — Hermes streams; arc CLI waited for the full response.
   Fixed: `prime()` + `streamConversation` in the `-q` path (cycle 2).
5. **Empty-response handling** — arc classified "missing choices" as
   `.permanent` and died instantly; Hermes retries with a storm guard.
   Fixed (cycle 1): `LLMError.emptyResponse`, retryable + storm cap.
6. **Tessera relay wedge** — bounded-handshake gap + missing teardown caused
   a reproducible SIGTRAP (`AsyncHTTPClient` deinit). Fixed (cycle 1):
   25s connect bound, `healthCheck()`, file-store fallback, explicit teardown.
7. **Parallel-tool-call guidance** — Hermes injects batching guidance into
   the system prompt; arc's prompt does not. Behavioral effect observed
   (Hermes batches more per turn); candidate prompt-parity improvement.
8. **Tool-aware guidance blocks** — Hermes injects memory/session-search
   guidance per loaded tool; arc does not. Same category as 7.

## Changes shipped per cycle

- **Cycle 1** (`1c178d9`): empty-response recovery + storm guard;
  Tessera bounded connect/healthCheck/fallback/teardown; metadata-driven
  `max_tokens` + deepseek metadata entry; tests.
- **Cycle 2** (`5cdf4e8`): `reasoningEffort`/`maxOutputTokens` config
  plumbing (ArcConfig AgentConfig/ModelConfig + ArcAgent Configuration);
  CLI streaming via `prime()`/`streamConversation`/`shutdownHTTPClient`.
- **Cycle 2b** (`4849f36`): LLMClient 3-arg `complete`/`stream` promoted to
  real protocol requirements (critical: existential dispatch was silently
  dropping `reasoning_effort` for ALL conformers); pipe-safe stdout flush
  (synchronizeFile raises on pipes); ParityConfigTests; PromptArchitecture
  suite serialized (global tool-store race).

**Tests: 270/270 green (19 suites).** CLI `arc chat -q` now streams with
visible tool activity, survives piped stdout, and honors Hermes parity knobs.

## Recommended next steps (not yet implemented)

- Populate `~/.arc/skills` with high-value Hermes skills (`plan`,
  `test-driven-development`, `technical-documentation`, `github-*`) — user
  decision; would move planning behavior toward Hermes' shape.
- Prompt parity: add `PARALLEL_TOOL_CALL_GUIDANCE` + per-tool guidance
  blocks to the stable tier.
- `serve` path: same health-check fallback as `chat` when Tessera is down.
