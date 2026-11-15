# UX gates — Scripts/README-gates.md

Zero-dependency UX assertion suite for the arc web UI. Assertions live **in the
page** (probe IIFEs); a tiny CDP driver (`ux-drive.mjs`, native `fetch` +
`WebSocket` only — no npm, no packages) does the driving. Requires Node ≥ 22.

## Run

```sh
node Scripts/ux-gates.mjs                # every gate
node Scripts/ux-gates.mjs --only=contrast         # just WCAG AA contrast
node Scripts/ux-gates.mjs --only=interactions
node Scripts/ux-gates.mjs --only=scroll
node Scripts/ux-gates.mjs --only=focus          # focus matrix (A12)
node Scripts/ux-gates.mjs --only=draft          # draft identity + seed (A14)
node Scripts/ux-gates.mjs --only=composer        # Enter / Shift+Enter / IME / slash / clear (A15)
node Scripts/ux-gates.mjs --only=theme          # aria-pressed selected contract (A15)
node Scripts/ux-gates.mjs --only=motion
node Scripts/ux-gates.mjs --only=regression
node Scripts/ux-gates.mjs --only=schemes
node Scripts/ux-gates.mjs --strict            # skips count as failures
```

**The ship gate** — one command for the whole program's exit condition:

```sh
Scripts/ship-gate.sh          # zero-JS + make verify + every gate group, PASS/FAIL per row
```

It asserts the absences (`Assets/overlay.js` gone, no `.js` under `Sources/`, no
source naming the deleted plumbing, an empty asset manifest, no `/ui/init.js` in
the served document), then runs `make verify` (suite + pin) and every gate group
above with `focus` first (the one group whose reads are state-sensitive), and
prints one PASS/FAIL line per row. **No row is exempt**: the allowlist that used
to carry `tab budget` and `delete flow` is empty, and an empty allowlist excuses
nothing (the known-red branch is guarded so it cannot), so any red row fails the
script. It needs a **fresh** daemon serving :8890 — see §"The fresh-daemon rule".

The daemon must already be serving the UI (`arc serve` → http://127.0.0.1:8890,
override with `ARC_UI_URL`). Chrome is launched headless on a throwaway
`--user-data-dir` (or `--attach` to a running Chrome exposing
`http://127.0.0.1:9222/json`). Exit code: `0` all pass (skips are not
failures), `1` any gate failed, `2` driver/infra error. A gate that cannot
exercise its assertion (e.g. the configured model produced no live turn for a
streaming check) reports `[SKIP] reason` instead of passing or failing — it is
a loudly-labelled environmental non-result, not a whitewash. `--strict` turns
every skip into a hard failure.

Artifacts (all gitignored — regenerate, don't commit):

| file | contents |
|---|---|
| `contrast-report.json` | WCAG AA sweep: failures `{view, theme, text, fg, bg, ratio, required}`, per-view/theme counts |
| `gates-report.json` | interactions / motion / regression results with raw detail |
| `assets/schemes/<slug>-chat.png`, `-settings.png` | 27-scheme contact sheet (54 PNGs) |
| `schemes-index.json` | each scheme's computed key tokens (bg/text/accent/accentStrong/border) |

## The zero client script invariant (A17)

There is **no arc-owned JavaScript in this tree**, and that is a design rule, not
a state of affairs: the client is no-webui's engine (`/ui/webui-engine.js` + its
`-ext` asset), and every consequence arc once wrote lives in a framework
behaviour or in the sheet. Concretely:

- `find Sources -name '*.js'` prints nothing.
- `Sources/ArcWebUI/Assets/webui-assets.json` declares no types — the embed
  plugin generates one declaration per entry, so an entry that reappears is a
  script coming back through the other door.
- `AppShell.makeDocument` takes no script url, `AppShell.Assets` ships one asset
  (the sheet), and the served document carries the engine's tags and none of
  arc's.
- `ZeroClientScriptTests` (web UI suite) asserts all four, so a new `.js` fails a
  unit test before any browser gate runs. The old guard was a byte ceiling that
  had to be ratcheted down after every deletion; the honest ceiling is zero,
  because "the engine has no consequence for this" has no members left.

A capability the engine lacks is a **framework request** (a release, a versioned
behaviour and a vocabulary row), never a file here.

## What each gate asserts

1. **contrast (T14)** — for every text-bearing visible element in five views
   (chat with a conversation open, left panel, settings, delete modal, toast)
   in **both** themes, computes the effective background (walking ancestors to
   the first non-transparent `background-color`, compositing alpha) and the
   WCAG contrast ratio. Threshold 4.5 for normal text, 3.0 for large/bold text.
   Failures are real defects — fix them, don't raise the threshold.
2. **interactions (T15)** —
   - console-clean tour: zero errors/warnings (incl. `[WebUIEngine]`) from page
     load through a scripted tour (rail buttons, header buttons,
     `#drawer-toggle`);
   - popover matrix: Escape + outside-click for `#file-pop`, the composer chips
     (profile/model/think/workspace), and the session context menu;
   - tab budget: from a fresh load in an empty conversation, ≤ 13 Tab stops to
     `#composer-input` at 1440 and 768 with 20+ sessions. The 13th is
     `chat-clear-empty` ("Clear N empty chats"), which renders only while
     another empty chat exists; the clean-state trail is 12 at 1440 and 9 at
     768. Measured at D2b: 13 with the control in the trail, 12 without;
   - slash: `/` opens, typing filters, Enter inserts;
   - delete: modal → deleted → toast + Undo → restored → final delete;
   - dock: 5 × open/close with a stable anchor and no engine warning.
3. **motion (T16)** — with `Emulation.setEmulatedMedia` `prefers-reduced-motion:
   reduce`: ws-panel slide, toast enter, and the stream shimmer resolve to
   `animation-duration ≈ 0s` **and** the element still reaches its final
   visible state (opacity 1, transform none).
4. **regression (T17)** — round-2 re-run: scroll read-back stays pinned
   mid-stream (SCROLL_PAD), composer ghost draft survives reload, `dd-pop`
   closes on Escape, Enter-to-send works. The SCROLL_PAD row streams its turn
   into the gate's own seeded long chat (see §"D6 acceptances"), so the
   container has room from the first frame instead of waiting for a fresh
   chat's reasoning phase to grow one.
5. **round4 (T34)** — the navigation/scroll fundamentals the round-4 fix wave
   landed: a rail return restores the chat scroll position (UX-39), the
   composer shows the CURRENT chat's draft across a live session switch
   (UX-40), the session list keeps its position across a rail round-trip
   (UX-41), and `+` lands the caret in the composer (UX-45). When the open chat
   has no room, the UX-39 row opens the gate's own seeded long chat (deleted
   through the app's delete flow at the end of the run) rather than SKIPping.
6. **schemes (T18)** — enumerate the schemes from the app's own settings grid
   (`[data-scheme-choice]` tiles — registry-driven, never hardcoded), click
   each, screenshot chat + settings, record computed tokens.
7. **focus (A12)** — no-webui owns focus, so this matrix reads the
   consequence in the real browser on the context-breakdown dialog (opened from
   the composer's context chip; the delete-confirm flow is base-red in some
   daemon states): (a) the patched-in dialog takes focus through its
   `data-focus-into`; (b1) Escape closes it and returns focus to the opener;
   (b2) the close control does the same; (c) Tab from the dialog's last
   control wraps inside `.modal-overlay`; (c2) Shift+Tab from its first control
   wraps backward (a real CDP key event with the Shift modifier); (d) a focused
   control whose patch replaces it keeps focus — measured on the attachment
   chip's ✕, which declares `data-focus-return` (empty = itself) and whose
   path-keyed id survives a composer patch, with a DOM-only mark proving the
   node really was replaced; (e) no console error or warning through the tour.
   The group opens the gate's seeded long chat when the active conversation has
   no message (the chip only renders for one that does). Every wait is
   deadline-bounded, and a missing frame fails the row.
8. **composer (A15)** — no-webui 2.17.0 owns the submit gesture and the clear,
   so this gate reads the consequence in a real browser: (e) the composer
   carries `data-submit-on-enter="plain"` and `data-clear-on-submit`;
   (d) with the slash menu open, Enter inserts the highlighted command and
   does **not** submit (the engine's listener is on the textarea element, so
   the menu's is a capture-phase document listener that stops propagation for
   Enter/Tab); (b) Shift+Enter inserts a newline and does not submit;
   (c) an Enter during an IME composition (`isComposing`, and the legacy
   `keyCode === 229` spelling) submits nothing; (f) a whitespace-only Enter
   sends nothing — the observed contract is that the engine's "successful" is
   the submit event, so the field clears while the server refuses the blank
   text; (a) Enter submits, the transcript gains the message, and the field
   still reads empty after the replacing patches that follow (3.1.0 clears the
   draft store with the control, so the echo cannot come back — `ZeroClientScriptTests`).
9. **theme (A15)** — `aria-pressed` is the theme-selected contract:
   (a) exactly one `[data-theme-choice][aria-pressed="true"]` at load and it
   matches `<html data-theme>` (the engine's boot press runs after the server's
   render, so the row polls to a deadline); (b) a press of a different card
   leaves exactly one pressed, moves `<html data-theme>` with it, paints the
   sheet's `[aria-pressed="true"]` rule on that card (computed border/shadow
   differ from an unpressed card), and produces no `.active` class anywhere;
   (c) no client script is served — `/ui/init.js` is 404 — and the page loads
   no script of arc's at all: only the engine's two tags resolve, because A17
   deleted the file that could have carried a theme mirror.

## Probes

Page-context IIFEs, one per file — each defines a `window.*` object with pure
read-only functions and **also works pasted into a browser console**:

- `ux-contrast.js` → `window.uxContrast` (`sampleView`, `effBg`, `ratio`…)
- `ux-gates.js` → `window.uxGates` (state, popovers, slash, sessions, modal,
  toast, stream, drawer, workspace, focusables, activeElement, composerState,
  themeState…)
- `ux-schemes.js` → `window.uxSchemes` (`list`, `active`, `tokens`)

Manual paste example:

```js
// with the UI open on the settings view, paste:
fetch('/Scripts/ux-contrast.js')        // served by the daemon? no — read the
  .then(r => r.text())                  // file and paste its contents instead.
```

The files are plain JS with no dependencies; paste the file contents into the
DevTools console, then call e.g. `uxContrast.sampleView({root: document.body})`
or `uxSchemes.list()`.

## Wiring notes

- PNG screenshots are taken by the driver (`Page.captureScreenshot`) and
  **never viewed by the gate itself** — the orchestrator eyeballs the scheme
  contact sheet.
- The gates create throwaway `UXGATE*` probe sessions and delete them through
  the app's own delete flow at the end; the owner's conversations are never
  touched. The active scheme/theme are restored to whatever the run found.
- Probe turns are **tool-free by design**: `ensureProbeSession` appends
  "reply with the single word: ok. Do not call any tools." to every probe
  message. A probe that reads like a research task sends the model into a
  multi-minute tool loop; `waitStreamEnd` (180 s) then gives up, the still-live
  turn races the later gates' clicking, and the console tour / dock checks
  fail on `[WebUIEngine] Element not found: #live-turn-thinking` — a race the
  gates' own authors documented as avoidable. Keep probe messages answering in
  seconds.

## Known-red set (2026-11-14)

Baseline: `8a8574f0` on `tessera`, clean tree. Measured with a freshly built `.build/debug/arc`
serving :8890 and the live session store, before any slice of the deferral remediation landed.

- strict matrix: `node Scripts/ux-gates.mjs --strict` → **59 of 70 rows**: 6 failed, 5 skipped (exit 1)
- suite: `make verify` → **1978 executed** (15 daemon + 785 web UI + 1178 core; exit 0)
- ship gate: `Scripts/ship-gate.sh` → **16 passed / 2 failed** (exit 1: `residue`, `draft`)

Deltas from §0 of `.hermes/plans/2026-11-14_212853-arc-deferral-remediation.md`, measured and
left alone: the plan records 60/70 (5 failed / 5 skipped) and a ship gate of 18/0. This baseline
measured 59/70 (6 failed / 5 skipped) and 16/2. The extra strict-matrix red is
`regression · composer ghost draft on reload`. Both ship-gate reds are probe rows: `residue`
aborts after `(a1)` `{"ok":false,"reason":"the row menu did not open"}` with
`ux-gates.mjs failed: Cannot read properties of undefined (reading 'length')` (exit 2), and
`draft` failed only on `a same-identity patch keeps the reader's keystrokes`, which passes 5/5 in
an isolated `--only=draft` run. The contrast row is also a different defect than §0 records:
§0's 13 `#818CF8` link failures (4.39:1) did not reproduce; the run measured one failure, the
light-theme `Sidecar running` hint at 3.95:1, and the delete-modal view was not sampled in either
theme (`modal did not open`). No threshold, deadline or poll bound was moved; no row was skipped,
edited or repaired.

| row | verdict | measured detail |
|---|---|---|
| `contrast · WCAG AA both themes (chat, panel, settings, modal, toast)` | FAIL | `{"totalFailures":1}` — `settings/light ratio=3.95 need≥4.5 "Sidecar running" rgba(61,139,82,1) on rgba(244,249,253,1)`; `contrast dark/delete-modal: modal did not open` and `contrast light/delete-modal: modal did not open` |
| `interactions · tab budget (<=12 stops to composer, 1440 + 768)` | FAIL | `{"768":{"stops":9,…},"1440":{"stops":15,…}}` — at 1440 the composer is the 15th stop (`"focusableCount":40`), over the then-budget of 12; at 768 it is the 9th (`"focusableCount":28`) and passes; trail arrays elided. (The row is `<=13` since D2b, with the measured trail: 13 includes `chat-clear-empty`.) |
| `interactions · delete flow (modal -> deleted -> toast with no Undo -> stays deleted)` | FAIL | `{"modalOpen":false,"gone":false,"toast":{"present":true,"count":0,"items":[]},"deletedToast":false,"noUndo":true,"finalGone":false,"finalGoneStaysGone":false,"beforeCount":137,"afterCount":137}` |
| `regression · composer ghost draft on reload` | FAIL | `{"drafted":"UXGATE draft 55235","afterReload":"","pass":false}` |
| `regression · dd-pop Escape closes` | FAIL | `{"opened":false,"closedByEscape":true,"pass":false}` |
| `round4 · new-chat probe cleaned up via the app delete flow` | FAIL | `{"sid":"CCD1555C-3AAA-44DC-A7F1-7EF7E00D4593"}` |
| `scroll · rail return restores this chat’s scroll (UX-39, data-scroll-key)` | SKIP | `the open chat has no usable scroll range (room=0); the emitted memory key is "90705A7A-7FD8-4341-9B3B-D9B40B0246F6"` |
| `focus · the gate can reach a dialog opener with no dialog open` | SKIP | `no conversation with at least one message is open, so the surface (the composer’s context chip (#ctx-chip-summary) → the context-breakdown dialog (#ctx-pane-overlay, a .modal-overlay card)) is not rendered — open a chat with a reply and re-run` |
| `residue · (b2) a work-log round copies its activity digest` | SKIP | `no reachable transcript has a tool round (scanned 10 of 138 chats) — the "copy this activity" control only renders for a turn that called a tool` |
| `regression · scroll read-back mid-stream (SCROLL_PAD)` | SKIP | `no scrollable range appeared within 20 s of the turn (room=0) — at-bottom follow expected, pin untestable`, with `"before":{"top":0,"h":670,"c":670}` |
| `round4 · rail return restores chat scroll (UX-39)` | SKIP | `the open chat has no usable scroll range (room=0) — run with --only=regression in the same session so the streaming chat leaves content, or open a long conversation first` |

The `focus` group reported a single precondition row in this run rather than per-row verdicts, so
§0's `focus (d)` skip did not appear as its own row; the group's only row is the skip above.
Two rows are order-sensitive: `regression · composer ghost draft on reload` passed in an earlier
strict attempt that aborted in the `schemes` gate (`waitFor(chat view) timed out; last=false`,
exit 2, not a measurement), and `round4` UX-40/UX-41 failed in that same aborted attempt but
passed in the frozen one. The frozen numbers above are from the completed `--strict` run.

## Known-red set — final (2026-11-15)

**This is the measured end state. The §"Known-red set (2026-11-14)" section above is the dated
baseline it supersedes** — kept as it was written, because it is the record of what the base
commit actually did, not a description of today.

Measured on `tessera` with a freshly launched `.build/debug/arc` (sha256 `bf54a737…74df51`)
serving :8890, its build unchanged across every run: the pair at `1c7f158a`, the ship gate at
`0a0b4d85` — the delta between the two is the ship-gate allowlist, which no `--strict` run executes.

- strict matrix: `node Scripts/ux-gates.mjs --strict` → **78 of 78 rows: 0 failed, 0 skipped**
  (exit 0), **twice in a row** on a fresh daemon each time (493 s and 493 s). The two runs'
  row-name sets are identical (78 names) and their non-PASS sets are both empty, so the
  symmetric difference is empty — the matrix is deterministic, not merely green once.
- suite: `make verify` → **1,979 executed** (15 daemon + 786 web UI + 1,178 core; exit 0).
- ship gate: `Scripts/ship-gate.sh` → **18 passed / 0 failed** (exit 0) with `KNOWN_RED` **empty**.
- **There are no environmental skips.** The last one, `residue · (b2) a work-log round copies its
  activity digest`, skipped because *"no reachable transcript has a tool round (scanned 10 of 149
  chats)"* — the "Copy this activity" control only renders for a turn that called a tool, and the
  live store had no such turn. It is now **exercised**: the row falls back to a transcript of that
  shape seeded through `FileSessionStore` and opened by the app's own deep link (the D6 facility),
  UXGATE-titled, tracked by sid, and deleted through the app's own delete flow inside the row.
  Both runs report `origin: "seeded"` with the clipboard reading back the control's `data-copy`
  value and the engine's `Copied` toast.

One earlier attempt at the pair is preserved as **not a measurement**: it reported **77 passed rows,
0 failed, 0 skipped** and then exited 2 in the `schemes` group (`ux-gates.mjs failed:
waitFor(scheme ares active) timed out; last=false`), which is exactly the class D2c describes — an
infra abort, not a row verdict. It was re-run once after a daemon restart; the pair above is the two
completed runs. A run that does not print its `N/N gates passed` tally line is not evidence of
anything, however good its rows looked.

### The fresh-daemon rule (D2c.3)

**Restart the daemon before every `--strict` run, and before the ship gate.** A daemon that has
served many turns ages into a state where the composer never quiesces after `streamEnded`
(`stable=false`) and the session list's `scrollTop` reads `-1`; popover opens are then lost and the
UX-40/41/45 rows fail. Measured A/B: the aged daemon failed a script that a fresh pid passed 6/6.

The restart is not `kill` and hope:

1. kill the daemon, then wait until `curl -sf http://127.0.0.1:8890/` **fails** *and* port **8080 is
   free** — a prior run bound :8080 while only :8890 was checked, so both are proved;
2. relaunch `.build/debug/arc serve` from the repo root, poll to READY, and confirm HTTP 200 twice;
3. record the pid and the binary's sha256 with the numbers the run produces.

The ship gate's fresh-daemon requirement applies to **every group it runs**, not just `focus`. If a
row fails with `stable=false` or a negative scroll offset, the first remedy is the restart, not a
threshold.

## D6 acceptances (2026-11-15)

Slice D6 of `.hermes/plans/2026-11-14_212853-arc-deferral-remediation.md` closed four
coverage gaps. Three were exercised (the rows below are hard rows now); one is an
acceptance with the unit proof named, because the live boundary is impractical.

### A seeded long chat, through the app's own storage path

UX-39 (a rail return restores the open chat's offset) needs a transcript with real
scroll room, and a client-side pad cannot supply it: the rail round trip re-renders
the transcript from server state, so a padded fixture is gone by the time the offset
would be restored. Measured at the D6 base: `room=0` on the empty active chat, so
`--only=scroll` and `--only=round4` both SKIPped, and `focus` skipped its whole group
because the context chip only renders for a conversation with at least one message.

The gate now writes one session record — seven long turn pairs, `UXGATE` in the title
and the first message — into `~/.arc/sessions/` (`FileSessionStore`'s directory) and
opens it through the app's own deep link: a load of `/?s=<sid>` runs
`AppState.openDeepLink` → `reloadSessions` → materialize (`WebUIHost`'s page provider),
which is also what makes the row appear in a running daemon's list. No provider turn is
involved, the record is tracked by sid, and it is deleted through the app's own delete
flow with every other probe (the run's cleanup reports `UXGATE rows 1 -> 0`). The
owner's conversations are never opened by it.

### Exercised

| row | how |
|---|---|
| `scroll · rail return restores this chat’s scroll (UX-39, data-scroll-key)` | measured on the seeded chat: `room=3896`, `before=900`, `after=900`, pass |
| `round4 · rail return restores chat scroll (UX-39)` | same chat; the row now polls each side of the rail round trip before reading it (a fixed settle read `-1` on a slow patch and failed a restore that had landed 250 ms later) |
| `focus · (d) a focused control whose patch replaces it keeps focus (T26)` | the attachment chip's ✕: the chip declares `data-focus-return` (empty = itself, `Views.swift`), the composer patch replaces the node (a DOM-only mark proves it), and focus lands on the NEW ✕ because its id is path-keyed (`att-del-<enc(path)>`). The undeclared clone lap in the same record still shows focus falling to `<body>`, which is what makes the declaration the mechanism |
| `focus · (c2) Shift+Tab from the dialog’s first control wraps inside .modal-overlay` | `driver.pressShiftTab()` — a real `Input.dispatchKeyEvent` with `modifiers: 8` (Shift). Without the trap the key walks out of the overlay into the page behind it, so `activeInDialog` is the falsifiable part; the pane currently holds one tab stop and the row records the count |
| `focus` group reachability | when the active chat has no message, the group opens the seeded chat and takes the resting page again instead of SKIPping |

The attachment flow is the app's own (`#cb-file` → `#file-path-input` → `#file-attach`);
it attaches `Scripts/README-gates.md`, so `settings.recentFiles` gains that path — the
app's real consequence of a real action, not gate-faked state. The chip is removed by
its own ✕ at the end of the row, and the caret then lands in the composer through the
textarea's `data-focus-on-appear` (measured: `active: composer-input`).

### Accepted, not exercised

`UploadTokenStore` eviction at the live 257-tab boundary. The store keeps the last 256
served render tokens (`defaultCapacity = 256`, `WorkspaceUpload.swift`) and drops the
oldest; proving the boundary in a browser needs 257 real page loads before an upload
from the first tab, and the store has no other observable surface (an evicted tab's
upload is a 403, not a rendered state). The cap is unit-tested twice, at capacity 3:

- `UploadRouteTests · "the token store keeps a bounded window and drops the oldest token"`
  — records a, b, c, d at capacity 3 and asserts `a` is evicted, `d` is present, and a
  re-served live token does not consume a second slot;
- `PushFanoutTests · "an old page falls out of the set at capacity"` — records five
  tokens at capacity 3 and asserts the snapshot is exactly `[tok-2, tok-3, tok-4]`.

Both exercise the same `record`/`order.removeFirst()` arithmetic the 257th page load
would, so this is accepted with that proof rather than re-derived in a browser.
