# Spec 08 — Web UI

The board view and its editing surfaces. **This is the kanban page** — it
*replaces* the existing cosmetic settings-backed kanban page (the
lanes/popovers board built earlier); its interaction patterns (arm-confirm
box, popover add/edit menus, persistent top bar, structural-change-only
liveness tick) carry over intact. Everything renders server-side from
`BoardDocument` (no client state beyond disclosure/selection).

## 1. Layout

- **Top bar** (always visible, even for an empty board — same rule as the
  old page): board name left; right side: "+ Column", "+ Row", "+ Root"
  (user verbs), a **Settings** popover, and a graph-health indicator
  (green dot / warning count from spec 02 §4).
- **Settings popover** (spec 01 `BoardSettings`): profile dropdown,
  cycle budget, max depth, mint allowance, stale-motion timeout,
  triage cooldown — defaults pre-filled, all editable, saved through
  the daemon's edit path.
- **Lanes** = rows, columns = the grid. Empty-board state: "No lanes yet —
  open + Row" blank, top bar stays.
- **Cards** render: title/goal (ellipsized in a rounded box, basename chips
  for attachments), readiness badge (runnable / waiting-on-children /
  running / done), generation depth, lane position. Click → card sheet
  (§3).
- Column header shows kind (icon), edge count, and a ⋮ popover (rename,
  kind, edges, delete-with-arm-confirm).

## 2. Graph editor

- Edge list lives in each column's popover: outgoing edges with
  decision/label/policy; add-edge form (destination, decision, outcome
  label, policy); remove.
- **Edit-time validation** results render inline: warnings as subtle badges
  on the offending column; hard errors block the save with the violation
  named (server-side check via `BoardGraphEdit` application, spec 02 §3 —
  the UI never self-approves a graph).
- The agent has no graph-editing surface (spec 02 §5): no proposals UI.

## 3. Card sheet

Body sections in order: contract (goal / input + passing mode /
done-condition), lineage (parent link, birth edge, last edge, generation —
immutable fields rendered read-only), provenance list (each transition with
reasoning + decidedBy), traversal counts, result + attachments (chevron
expand, byte size — the script-run disclosure pattern), lane move control.

## 4. Root panel

- Root list with state chips: running / green / yellow / needs-user pile.
- Green root: evidence chain table (clause → cards → reasoning) — the
  review surface (spec 06 §1).
- Yellow root: attempts timeline + "what the user must provide" as the
  primary call-to-action; **Resume** button (arm-confirm), with an *optional*
  resume-context text field that becomes `resumeContext`.
- Root creation form: title + definition-of-done (textarea, one clause per
  line — the explicit clause structure spec 06 §1 maps evidence against) —
  the only root-creation surface.

## 5. Liveness

The `scheduled-tasks`-style interval service pattern: 2s tick, fingerprint
of rendered board fields, structural change broadcast **only when something
moved**. A card running (border pulse), queue advance, graph edits, settings
changes, and artifact additions all arrive via this single channel. No
per-keystroke re-renders (the earlier cursor-refresh lesson). Boards
selected independently — switching boards is a selection change, all
boards stay live server-side.

## 6. Non-goals for v1

- Drag-and-drop card moves (card moves are engine verbs; the UI offers
  explicit move/release actions instead).
- Multiple boards in one view (board switcher selects one document).
- Live streaming of the executing card's turn (the card sheet shows state;
  turn transcripts live in the session machinery).

## 7. Tests

- Golden render fixtures: empty board, board with running card (pulse),
  green evidence table, yellow report, graph warnings, settings popover
  with defaults.
- Arm-confirm on: column delete, edge delete, root resume, card release.
- Structural-only tick: unchanged board pushes nothing (the existing test
  pattern).
- Server-side refusal: UI-crafted graph edit violating hard rules is
  refused and re-renders with the violation.
- Settings save round-trips through the daemon and re-renders with new
  values; invalid values refused server-side.
