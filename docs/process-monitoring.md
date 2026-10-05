# Process Monitoring & Reactions

How an agent can watch the active processes of the machine it runs on
(and machines reachable over SSH), react to lifecycle and health
changes, and stay correctly scoped and safe doing it. This document
scopes the capability for arc-agent and contrasts it with the reference
(Hermes) behavior. It is a design/planning document — no code herein.

## 1. What exists today

### Reference (Hermes) — no OS process watching

Hermes does not inspect the machine's process table. Its interaction
with active processes is limited to processes it spawns itself:

- `terminal` executes commands through an *environment interface*
  (`TERMINAL_ENV=local` = host; otherwise Docker, Singularity, Modal,
  Daytona, or an SSH backend). The shell command runs in whatever env the
  interface provides.
- `tools/process_registry.py` tracks only `terminal(background=true)`
  sessions: rolling 200 KB output buffer, `poll`/`wait`/`kill`,
  crash-recovery checkpoint file, session-scoped registry. Nothing else
  is ever listed, signaled, or observed.
- `agent/monitoring/` is telemetry *about Hermes itself* (gateway
  health, cron health, redaction policy, OTLP export) — not processes.
- Reactions to machine state exist only through its own scheduling
  surfaces: cron jobs, inbound webhooks, approval prompts.

Conclusion: "watch and react to machine processes" is new ground for
both codebases. Parities matter here only for the *parts arc already
mirrors* (process registry, hooks, cron, approvals).

### Arc-agent today (reuse surface)

| Piece | State | Reuse for this feature |
|---|---|---|
| `ProcessRegistry` actor (`Sources/ArcAgentCore/Process/`) | Tracks arc-spawned background terminal sessions only; `Snapshot` model, reaper | Security anchor + v0 target set (arc owns these PIDs) |
| `ProcessTool` (`process` toolset) | `list/poll/log/wait/kill` for own sessions | Pattern for structured, non-shell tool surfaces |
| `HookBus.emit(event, context)` + handlers | File handler, exec handler (`/usr/bin/env` + script), webhook handler | Reaction engine: `process:*` events plug in here (`gateway:startup` is the precedent) |
| `CronScheduler` + `CronJob` | Jobs = schedule + agent prompt + `isActive` | "Process jobs": watcher-triggered agent runs |
| `ApprovalManager` | Dangerous-command patterns (`sudo`, `shutdown`, `reboot`, `chmod 777`); smart approval; manual mode | `process` control actions must be gated here |
| `security.toolGateway` (`ToolGatewayConfig`, `rules: []`) | Per-tool allow/deny rule engine | Enforcement anchor for a `process` toolset |
| `AgentPowers` | Skills/memories lockdown only | Extend with process-control powers |
| Terminal tool | Local execution only (SwiftSlash/Process); **no SSH**, no remote env | Remote transport must be built |

Gaps to note: no host process observation of any kind; no SSH transport;
`kill`/`pkill` are **not** in the dangerous-command pattern set (a gap
even for the existing `process` tool's kill action — should be
classified); no process-related powers or tool-gateway rules yet.

## 2. Security posture (design constraints)

These are the invariants any plan must satisfy:

1. **Scoped by default.** The watcher only observes processes that match
   an explicit allowlist (`targets`). A process that matches nothing is
   invisible to the watcher and to the agent tooling.
2. **Observe-only by default.** Listing/inspecting/emitting events is
   the default; any control action (signal, kill, restart, trace) is
   opt-in per target (`control: true`) *and* routes through
   `ApprovalManager` as `.dangerous` (and through `toolGateway` rules and
   `AgentPowers`).
3. **No shell interpolation.** All observation uses a fixed `ps`
   invocation with explicit `-o` columns (and `ww` to defeat truncation
   on macOS); all control uses `Process` with argument arrays — never
   `bash -c` with agent-derived strings. Remote commands are fixed
   templates, not freeform shell.
4. **Identity, not just PID.** PID reuse races are real; a match is the
   triple (pid, name, start time / `lstart`). Snapshot diffs carry the
   full identity so a recycled PID cannot be mis-attributed.
5. **Never touch system-critical or unrelated processes.** Default deny
   set: pid 1, the agent's own process tree (and its ancestors),
   kext/kernel threads, sshd on remote hosts, launchd/systemd. The deny
   set is configurable but always applied before the allowlist.
6. **Redaction.** Command lines and args can carry secrets; event
   payloads and logs redact values matching configurable patterns
   (mirrors Hermes `monitoring/redaction.py`).
7. **Resource bounds.** Poll interval floor, event-rate cap, max target
   count, bounded event history; no `top`-style busy loops; `sample` /
   `spindump` / `sudo` are never offered implicitly (TCC prompts and
   root escalation are surprises, not defaults).
8. **Remote = read-only template transport.** SSH observation runs only
   allowlisted commands (e.g. a fixed `ps` line). Keys are per-machine,
   `BatchMode` + pinned host keys, no agent forwarding; control actions
   on remote machines are gated twice (remote key scope + local
   approval).

## 3. Architecture (shared by all plans)

```
                    ┌────────────────────────────────────────────┐
                    │            ProcessWatchService (Service)     │
                    │  Second Law: one long-lived Service in the   │
                    │  daemon tree; shutdown = stop observers      │
                    └───────┬───────────────────┬──────────────────┘
                            │                   │
    ┌───────────────────────▼─────┐   ┌─────────▼──────────────┐
    │ Observer                    │   │ Scoping engine          │
    │ snapshot poll | native      │──▶│ target allowlist match  │
    │ kqueue/inotify | sidecar    │   │ + deny set + identity   │
    │ stream (local & remote)     │   │ + thresholds            │
    └─────────────────────────────┘   └─────────┬──────────────┘
                                                │ matched events
                     ┌──────────────────────────▼───────────────┐
                     │ Diff/match engine → ProcessEvent          │
                     │ started | exited | restarted | cpu/mem    │
                     │ threshold | pattern | unhealthy           │
                     └───────────────┬───────────────────────────┘
                                     │
        ┌────────────────┬───────────┴────────────┬────────────────┐
        ▼                ▼                        ▼                ▼
   HookBus           Notification             Control path      process_*
   process:*         (toast/session          (gated: approval    tool surface
   file/exec/        note, gateway           + powers + tool     (list/inspect/
   webhook           message)                gateway + target    signal/watch)
   handlers                                   allowlist)
```

Components:

- **Observer** — sources of process truth. Variants in §4.
- **Scoping engine** — the security heart: allowlist entries
  (`name`, `pathPrefix`, `cmdline` regex, `listenPort`, `pid`, `uid`),
  deny set, thresholds (`cpuPct`, `memPct`, `restartWindow`), identity
  (pid + name + start), per-target control permission.
- **Event model** — `ProcessEvent { type, target, pid, identity,
  cpu, mem, command, workstation }`; typed `HookBus` event names:
  `process:started`, `process:exited`, `process:threshold`, etc.
- **Reaction engines** — (1) `HookBus` handlers (file/exec/webhook),
  (2) cron-style **process jobs** (on match, run hook or agent prompt —
  mirrors `CronJob`), (3) session notification (toast / gateway
  message), (4) agent tool surface (`process_watch list/status`,
  `process list`, `process inspect <pid>`, `process signal <pid>` gated).
- **Control surface** — `process signal/restart` tools; every action
  checked against (a) target allowlist `control:true`, (b)
  `ApprovalManager` danger, (c) `toolGateway` rule, (d) powers.

## 4. Feasible plans

### Plan A — Owned-process lifecycle events (v0, smallest)

Watch only processes arc spawned (`ProcessRegistry`) and registered
daemons. `Process.terminationHandler` already fires per session; relay
exit (with exit code/reason) into `HookBus` (`process:exited`,
`process:spawned`, `process:threshold` by output length), optional
session toast, optional process-jobs. Also classify the existing
`process` `kill` as dangerous in `ApprovalManager`.

- **Security:** zero new surface — no OS scan, no permissions, no new
  tools. Scoping trivially = arc's own children.
- **Effort:** ~1–2 days. **Dependencies:** none.
- **Why first:** proves the event/reaction pipeline (hooks, jobs,
  notifications) end-to-end with the safest possible target set.

### Plan B — Local scoped snapshot watcher (v1, core capability)

`ProcessWatchService` (Second Law Service) + snapshot observer: periodic
`ps -axo pid,ppid,state,pcpu,pmem,lstart,comm,args` (macOS) or `/proc`
scan (Linux; same model), parsed into `ProcessSnapshot` records
(explicit columns, `ww`, no shell), diffed against the previous
snapshot, matched against the scoping engine, emitted as
`ProcessEvent`s. Plus the agent tool surface: `process list`
(structured, filtered by targets), `process inspect <id>` (identity +
stat + matching rule), and `process signal` (observation-only default;
control requires `control:true` + approval).

- **Security:** allowlist-scoped; observe-only default; deny set;
  redaction; identity triple; control gated 4×.
- **Effort:** ~1 week core (macOS first; Linux second — same model).
- **Dependencies:** none (Foundation + stdlib only; `ps` is everywhere).
- **Caveats:** poll granularity (2–10 s floor), `ps` field-parsing
  brittleness (mitigated by `-o` + `ww` + tolerant parse), cost trivial
  at sub-10 s. On macOS, `ps` needs no TCC; other-user PIDs are visible
  but control is naturally same-uid only.

### Plan C — Remote observers (SSH-able machines)

Two transports, both built on Plan B's model:

- **C1 — templated SSH exec.** New small executor: system `ssh`
  (SwiftSlash, `BatchMode=yes`, pinned `StrictHostKeyChecking` per
  machine, keys from `~/.arc/ssh/<machine>.json`); runs only a fixed
  allowlisted command set (remote `ps` template; later a fixed
  signal template scoped to allowlisted pids). Poll rate reduced for
  remote (10–30 s). Zero new SPM deps; malicious remote output treated
  as data (no eval); host-key pinning; no agent forwarding.
  Effort ~2–3 days once Plan B exists. Simple, read-mostly.
- **C2 — remote `arc-watch` sidecar agent.** A small native helper
  (same pattern as sidebar sidecars / `SidecarProtocol` JSON-lines):
  built for darwin/linux, pushed to the target (or spawned over ssh
  stdio), streams events to the local machine, optionally accepts
  control commands over the same channel. Enables native observers
  (§Plan D) on remote machines and event push (no polling over the
  wire), and can run as a service on long-lived hosts.
  Effort ~3–5 days after Plan B. The shipped answer for "fleet"
  monitoring; matches the product's sidecar philosophy (sandboxed
  separate process, JSON-lines protocol).
- **Security notes (both):** remote observation is read-only by default;
  control must be explicitly enabled per machine *and* per target;
  remote keys are scoped (`command=` restrictions or a dedicated key per
  machine); never import remote files/scripts (no `source`), no
  user-controlled argument passed to a remote shell.

### Plan D — Native event observers (local optimization of B)

Replace polling with push where the OS offers it:

- macOS: `kqueue` (`EVFILT_PROC` NOTE_EXIT/NOTE_FORK/NOTE_EXEC) or
  `DispatchSourceProcess` — the Foundation-idiomatic route (note:
  libdispatch, same accepted-interop class as the existing
  `readabilityHandler`); also `log stream` for service lifecycle when
  filtering `system`/`launchd` is acceptable.
- Linux (local sidecar only, due to perms): `inotify` on
  `/proc/<pid>`-adjacent paths, `pidfd` (kernel ≥5.3), or proc connector
  (needs root — out of scope).

Hybrid: native events where available, polling as fallback (and always
as the SSI remote baseline). Effort +2–4 days on top of B; platform-
specific code; value = instant reactions + no wakeups.

### Plan E — Process jobs (reaction layer, independent)

Extend the cron model with `match` triggers rather than time schedules:
`{ match: {target, event, threshold}, when, run: hook | agent prompt,
approval }`. Sits on the same `CronScheduler` machinery (`CronJob`
carries prompt; add a second job kind or a `trigger` field), fires
`HookBus` events or agent runs when a watcher matches. Secured the same
way as cron prompts today. Effort ~2–3 days once A/B exist. This is what
makes the system *react* with judgment rather than just log.

## 5. Recommended layering

1. **A** (owned-process events + kill classification) — prove pipeline.
2. **B** (local scoped watcher + `process_*` tools) — the real
   capability and the security substrate.
3. **E** (process jobs) — reactions with agent judgment.
4. **C2/C1** (remote sidecar first — it reuses the sidecar playbook and
   enables Native-mode remote; templated-SSH as a lighter
   interim/fallback) — fleet reach.
5. **D** (native events) — latency polish over B/C2 where supported.

Each layer is shippable; B and E are the high-value middle; C2 is the
shipped-product answer for remote.

## 6. Open risks / decisions

- **`ps` parsing robustness** on both platforms (column width, `%cpu`
  semantics: macOS `ps` CPU% is decaying average, not instantaneous — a
  spike detector needs two samples or `pmap`-style aids; Linux `ps`
  likewise). Proposed: compare decay values; document semantics.
- **macOS TCC/notarization** for any control surface (`kill` same-uid is
  fine; `sample`/`spindump`/other-user control prompt or fail) — keep
  out of defaults.
- **Watcher recharge**: watching daemons the agent did **not** spawn is
  where risk concentrates; strong tone on explicit allowlist,
  approval, and `observeOnly`.
- **`pkill`-style wildcard control**: disallow entirely; only
  exact-identity signals through the API.
- **Hook event volume**: cap `process:*` emissions (rate + history) to
  keep hooks/cron from thrashing.
- **Naming/placement**: `ProcessWatch` in `ArcAgentCore/Process/` (next
  to `ProcessRegistry`), config under `~/.arc/config.json`
  `processWatch` block, powers entry `processControl`.
