# UX gates — Scripts/README-gates.md

Zero-dependency UX assertion suite for the arc web UI. Assertions live **in the
page** (probe IIFEs); a tiny CDP driver (`ux-drive.mjs`, native `fetch` +
`WebSocket` only — no npm, no packages) does the driving. Requires Node ≥ 22.

## Run

```sh
node Scripts/ux-gates.mjs                # every gate
node Scripts/ux-gates.mjs --only=contrast         # just WCAG AA contrast
node Scripts/ux-gates.mjs --only=interactions
node Scripts/ux-gates.mjs --only=motion
node Scripts/ux-gates.mjs --only=regression
node Scripts/ux-gates.mjs --only=schemes
node Scripts/ux-gates.mjs --strict            # skips count as failures
```

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
   - tab budget: from a fresh load in an empty conversation, ≤ 12 Tab stops to
     `#composer-input` at 1440 and 768 with 20+ sessions;
   - slash: `/` opens, typing filters, Enter inserts;
   - delete: modal → deleted → toast + Undo → restored → final delete;
   - dock: 5 × open/close with a stable anchor and no engine warning.
3. **motion (T16)** — with `Emulation.setEmulatedMedia` `prefers-reduced-motion:
   reduce`: ws-panel slide, toast enter, and the stream shimmer resolve to
   `animation-duration ≈ 0s` **and** the element still reaches its final
   visible state (opacity 1, transform none).
4. **regression (T17)** — round-2 re-run: scroll read-back stays pinned
   mid-stream (SCROLL_PAD), composer ghost draft survives reload, `dd-pop`
   closes on Escape, Enter-to-send works.
5. **round4 (T34)** — the navigation/scroll fundamentals the round-4 fix wave
   landed: a rail return restores the chat scroll position (UX-39), the
   composer shows the CURRENT chat's draft across a live session switch
   (UX-40), the session list keeps its position across a rail round-trip
   (UX-41), and `+` lands the caret in the composer (UX-45). Needs a chat with
   real scroll room for the scroll checks (otherwise those report SKIP — open
   a long conversation first or run with `--only=regression` in the same
   session so the streaming check leaves content behind).
6. **schemes (T18)** — enumerate the schemes from the app's own settings grid
   (`[data-scheme-choice]` tiles — registry-driven, never hardcoded), click
   each, screenshot chat + settings, record computed tokens.

## Probes

Page-context IIFEs, one per file — each defines a `window.*` object with pure
read-only functions and **also works pasted into a browser console**:

- `ux-contrast.js` → `window.uxContrast` (`sampleView`, `effBg`, `ratio`…)
- `ux-gates.js` → `window.uxGates` (state, popovers, slash, sessions, modal,
  toast, stream, drawer, workspace, focusables, activeElement…)
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
