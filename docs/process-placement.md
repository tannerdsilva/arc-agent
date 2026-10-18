# Process Placement

The contract for the process groups arc creates. Every child spawned through arc's two audited sites is
reachable by one signal at teardown, and nothing arc did not spawn is
reachable by it. Where the contract does not yet reach is named in §5: a
Foundation spawn cannot express a placement at all. This document is the reference for that contract: what
each placement means, why arc asks for the one it asks for, how the
guarantee survives a nested launch, and where it stops.

> **Status (implemented):** arc pins `SwiftSlash 6.0.0` and `swift-mcp 2.1.2`
> and passes `processGroup: .own` at both of its spawn sites
> (`Support/SubprocessRunner.swift`, `LLM/Adapters/ACPClient.swift`).
> Placement-aware teardown is in the transport of the pinned swift-mcp, so a
> child that itself spawns through the same library joins the enclosing group
> instead of escaping into its own. `Tools/DetachmentPolicy.swift` refuses a
> command line that detaches, and `TerminalTool` applies it ahead of both the
> foreground and the background path.

## 1. The three invariants

| | invariant | what it means | enforced by |
|---|---|---|---|
| **I1** | nothing is detached | arc never creates a process it cannot stop | `DetachmentPolicy` refusal + the source guard test |
| **I2** | nothing is orphaned | one signal on an arc-owned group reaches the whole tree | `.own` at both spawn sites + placement-aware teardown in the library |
| **I3** | nothing is a zombie | every child arc starts is reaped on every path | the library's reap-before-throw; arc never reaps by hand |

These are the acceptance criteria for the placement work. A change that
weakens one of them is a regression even if every test still passes.

## 2. How placement works

Placement is a property of the child's process group, decided once by the
spawner. SwiftSlash exposes it as a typed parameter on `ChildProcess`:

| placement | resolves to | teardown reaches | who asks for it |
|---|---|---|---|
| `.own` | the child leads a new group | the child and its descendants | arc, at every spawn site |
| `.inherited` | the child joins the enclosing group | whatever owns that group | a nested launch — the resolved default inside one |
| `.detached` | the child leads a new session | nothing else, by design | never, in arc |

The value matters twice: once when the signal is sent, and once when the
signal is *aimed*. `kill(pid)` reaches one process; `kill(-pgid)` reaches a
group. A child that leads its own group is reachable as `-pid`; a child that
leads none must be signalled by pid alone, because a negated pid there
addresses arc's own group. SwiftSlash 6 makes that rule explicit in
`signal(_:to:)`, and its own cancellation path follows the placement rather
than assuming a group. Before 6, a cancellation path that signalled `-pid`
while its sibling signalled `pid` silently could not stop one of the two
shapes — see §3.

## 3. The nested cascade

arc's interesting spawns are not direct children. A plugin tool is invoked by
spawning a *host*, and that host spawns the tool process — which may spawn a
build. The tree for one `pkg_overview` call:

```
arc                       (SubprocessRunner, .own -> leads its own group)
 └── swift-package-tool plugin      (.own: arc asked; host leads its own group)
      └── swift-package-tool overview   (nested launch -> .inherited)
           └── swift build -> swift-frontend
```

The host is spawned by arc's `SubprocessRunner`, so arc asks for `.own` and
the host leads a group. The host then spawns the audit tool through its own
SwiftSlash adapter **without asking for a placement** — so the library
resolves `.inherited` (a launch child joins the enclosing group) and the tool
plus its build land in the host's group. One signal on the host's group takes
the whole tree; arc's own group is untouched.

Measured on the real path (`arc plugins test … pkg_overview` against a cold
audit scratch, 60 s cap):

| pid | process | pgid | note |
|---|---|---|---|
| 77004 | `arc` | 76999 | arc's own group |
| 77009 | `swift-package-tool plugin` | 77009 | arc's child; leads its own group |
| 77010 | `swift-package-tool overview` | 77009 | inherited — joined the host's group |
| 77026 | `swift build` | 77009 | inherited |

Ten seconds after the 60 s cap fired, all three (77009, 77010, 77026) are
gone and no new zombie remains. The aborted run leaves ~1.3 GB of audit
scratch behind, which is expected — the scratch is a build product, not a
process, and it is not cleaned up by a tree that was killed mid-build.

**Why arc asks for `.own` explicitly rather than relying on the default.** A
top-level spawn resolves `.own` anyway, but arc is itself sometimes a launch
child. In that position the resolved default is `.inherited`, and arc's
teardown would downgrade from a group signal to a pid-only kill — it would
stop the plugin host and leave the host's tool and build compiling, then
report success. Asking for `.own` at the call site makes the guarantee hold
in every deployment, and keeps the intent visible where the spawn happens.

## 4. The refusal

`DetachmentPolicy` scans the command line before the child is created and
refuses a line that detaches:

- `setsid` / `nohup`, and a trailing `&` that hands the command to a shell
  that leaves it running.

The refusal is absolute — there is no override flag, no config key, and no
approval path that reaches it. It fires identically on the foreground path
and on `background=true`, because a detached command is unreachable on
either. The supported alternative is `background=true` on its own, which arc
tracks in its own registry and can poll, wait on, and stop.

`ProcessDetachmentGuardTests` holds the line structurally as well as
behaviourally: it scans arc's sources for a spawn that requests `.detached`
or a session of its own. The scanner strips comments and blanks string
literals first, so prose *about* detachment is not a call site, and the test
self-checks that masking before it trusts its own result.

## 5. Where the guarantee stops

Stated plainly, because callers rely on the edges:

- **A child that calls `setsid(2)` or `setpgid(2)` itself escapes.** No group
  mechanism can pull it back; that needs a container or a cgroup. The
  guarantee is *cooperative descendants*. In arc this is not a soft edge —
  `DetachmentPolicy` refuses the command line that would do it.
- **A `Foundation.Process` child joins arc's own group.** Foundation's `Process`
  has no placement knob, so five sites spawn that way: three short-lived helpers
  (a `ps` snapshot, a `/bin/kill` call, a hook interpreter) and three long-lived
  children that predate the contract (the background shell in `ProcessRegistry`,
  the cua driver in `ComputerUseTool`, a web-UI sidecar). They are reached when
  arc's own group is signalled at shutdown, but never by a *per-child* group
  signal — so a `ProcessRegistry` kill reaches the pid and not its grandchildren.
  `ProcessDetachmentGuardTests` pins the exact set, so a sixth site cannot appear
  unnoticed, and migrating one means giving it a placement-bearing spawner.
- **`SIGKILL` of arc cannot be handled.** Nothing runs, so the tree is
  reparented rather than signalled. `SIGTERM` and `SIGINT` are the graceful
  paths and both are handled by the service group.
- **Adopting escaped descendants is Linux-only.** `PR_SET_CHILD_SUBREAPER`
  (plus cgroup v2 `cgroup.kill` for real containment) has no macOS
  equivalent. arc does not promise re-adoption on either platform.
- **Escalation is the caller's.** The library delivers the signal you ask
  for and reaps; it does not escalate to `SIGKILL` on its own, and nothing
  should depend on it doing so.

## 6. What the version floor buys

- **SwiftSlash `6.0.0`** — placement is part of the spawn contract
  (`processGroup:`), and the signal API targets the placement
  (`signal(_:to:)`). On ≤ 5.0.3 the group was hardcoded in the C helper, so
  a nested launch could not join an enclosing group and a cascade could not
  be relied on past one level.
- **swift-mcp `2.1.2`** — its subprocess transport follows the child's
  placement. A build of the plugin host against 2.1.1 could not resolve
  SwiftSlash 6 at all, which is why the two bumps travel together.

Both are range pins (`"6.0.0"..<"7.0.0"`, `"2.1.2"..<"3.0.0"`), not `from:`
— SwiftPM resolves one version per dependency graph, and a `from:` on either
side lets a consumer drag the other back below the floor.

## 7. How it is tested

| suite | asserts |
|---|---|
| `SubprocessRunnerTests` | the child arc spawns leads its own group, in its own session |
| `SubprocessCascadeTests` | a nested launch joins the enclosing group; one group signal takes fixture + shell + grandchild |
| `DetachmentPolicyTests` | refusal/pass-through matrix; the refusal is identical on the foreground and background paths |
| `ProcessDetachmentGuardTests` | no source requests `.detached`; the scanner masks comments and self-checks that masking; the spawn census pins the audited set and names the Foundation carve-out |
| `ACPSpawnContractTests` | the ACP child leads its own group; a full `initialize` → `session/new` → `prompt` round trip against a fake peer; `shutdown()` reaps |
| `SubprocessLadderPlacementTests` (swift-mcp) | the transport's shutdown ladder stops a child that leads no group |

Placement is asserted in process, never through `ps`: the suites read
`pgid`/`sid` of the child and probe liveness with `kill(pid, 0)`, so the
assertions do not depend on shell plumbing or on timing luck.