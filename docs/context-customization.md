# Per-Session Context Customization

Status: Design proposal (no code yet)
Scope: arc-agent prompt/context pipeline

## Overview

Give each **session** a *context recipe* that controls the blob sent to the model:
what built-in context goes in, what is left out, and what custom context is added.
Recipes are layered so a session inherits a default from its **profile**, which in
turn inherits a **global** default, and the user may override either level per session.

The goal: no workarounds. A user should not need to invent a skill or edit a config
file just to add one line of context to a single chat, or to suppress a built-in
segment for that one chat.

## Context Sources (anatomy of the prompt blob)

| Source | Where it lives today | Tunable today |
|---|---|---|
| Stable tier: identity, tool index, rules, guidance, environment, personality | `buildSystemPrompt` in `Agent/ArcAgent.swift` | guidance/personality only (global config) |
| Context tier: project files (AGENTS.md, .arc.md, CLAUDE.md, .cursorrules) | `loadContextFiles` in `ArcAgent.swift`, gated by `config.injectProjectContext` | one global on/off |
| Volatile tier: Skills index, Memory, User Profile, timestamp | `ArcAgent.swift` | no |
| Conversation history: transcript + tail keeping + auto-compression | `messageHistory`, tail budget `min(20_000, limit/3)`, messages array at `:1654`/`:1951` | no |

Today the only knobs are **global** (`config.*`) or **profile-level**
(`Profile.contextSkills`, `personalityPrompt`). Nothing is per-session, and there is
no way to add free-form context or suppress a built-in segment for one chat.

## Levels and precedence

Context recipe is layered, resolved at prompt-build time:

```
global config.defaults  <  profile.contextDefaults  <  session.contextOverrides (wins)
```

- **Global** — the default recipe shipped in `config.json`, editable in the web UI.
- **Profile** — the default recipe used by every session under a profile. Inherits the
  global default, can override any segment, resets to global on profile switch.
- **Session** — the recipe for one chat. Inherits the profile default when the session
  is created or when the user switches to a profile; the user may alter it freely.

Any level may be left at "inherit" (nil) so it tracks the level above it, or set
explicitly to override. The web UI marks each row as **inherited** or **local**.

## Data model

```swift
struct ContextRecipe: Codable {
    var segments: SegmentSet?        // nil = inherit (track the level above)
    var customBlocks: [ContextBlock]? = nil
    var instructions: [String]? = nil
    var history: HistoryControl? = nil
}

struct SegmentSet: Codable {
    var memory: Bool = true
    var userProfile: Bool = true
    var skillsIndex: Bool = true
    var projectContext: Bool = true
    var environment: Bool = true
    var guidance: Bool = true
    var personality: Bool = true
    var timestamp: Bool = true
    var toolsIndex: Bool = true
}

struct ContextBlock: Codable {
    var id: String
    var label: String
    var content: String              // may contain {{date}}, {{model}}, ...
    var placement: Placement
    var enabled: Bool
}

enum Placement { case rules, context, promptTail, userTurn }

struct HistoryControl: Codable {
    var includeHistory: Bool = true
    var includeCompressionSummary: Bool = true
    var tailBudget: Int? = nil
}
```

Layering:

- `config.json` gains `context.defaults: ContextRecipe?`.
- `Profile` gains `contextDefaults: ContextRecipe?`.
- `Session` gains `contextOverrides: ContextRecipe?` (hangs off `Session.config`
  snapshot or a new field on `Session` in `Session/SessionStore.swift`).

A nil segment set at the session level means "inherit from profile"; a nil profile
set means "inherit from global"; a nil global set means "today's behavior."
The resolved recipe flattens the three layers at prompt-build time.

## Injection points

Each knob hooks into the existing pipeline; no rewrite:

| Knob | Hook |
|---|---|
| Segment toggles | Wrap each block in `buildSystemPrompt` (memory `:3330`, user `:3335`, skills `:3327`, project `:3311`, env `:3292`, guidance `:3262`, personality `:3305`) |
| Custom blocks → `.promptTail`/`.context` | Append after volatile tier `:3345` or in context tier `:3310` |
| Custom blocks → `.rules` | Append to stable rules `:3253` |
| Standing instructions | Append to rules/instructions `:3253` |
| Custom block → `.userTurn` | `composeUserContent` `:1175` / `injectTurnAdvisories` `:2611` |
| History control | compression `:1286`, tail budget `:1339`, messages assembly `:1654` |

## UI design

Three surfaces expose the same three levels, using the existing design vocabulary
(`set-section`, `set-row`, `dd` switch, `primary-btn`):

1. **Global — Settings → Context defaults.** Mirrors the Storage / Model-config
   settings pages. A "Context defaults" section with the segment toggles, custom
   blocks, instructions, and history controls. Editing here changes the shipped
   default for all profiles/sessions that inherit.

2. **Profile — Profile edit form.** A "Context" section alongside the existing
   "Context skills" section. Shows segment toggles and blocks, marked inherited
   (from global) where not overridden. A "Reset to global" per row.

3. **Session — the chat's Context panel.** The per-chat override surface. Same widget,
   marked inherited (from profile) where not overridden. A "Reset to profile."

A single reusable **context-recipe widget** renders any of the three levels (rows =
segment toggles, blocks list, instructions textarea, history controls), taking a
`level` tag so its inherited/local labels are correct.

### Segment toggle rows

Each built-in segment gets a `set-row` with a `dd` switch and an **inherited/local**
tag. When local, the row shows a subtle "override" badge; a per-row reset returns it
to inherit. "Reset all to inherited" resolves the whole section.

Segments:

- Memory
- User profile
- Skills index
- Project context
- Environment
- Guidance
- Personality
- Timestamp
- Tools index

### Reflect this feature in the UI

- The session list / chat header indicates when a session carries a **local** context
  recipe (a small "context" badge), so it is visible that a chat deviates from default.
- A **live preview** button (in all three surfaces) renders exactly what will be
  injected for the current level, marking the resolved source of each segment
  (`global` / `profile` / `session`), and an estimated token delta.

## Security and trust

Custom context is high-trust content injected into the system prompt. It should be:

- Demarcated (fenced as `## User Context`) so the model distinguishes user-authored
  content from framework guidance.
- Sanitized for control chars / render hazards (as `MemoryManager.scrub` does),
  while keeping user content otherwise verbatim.

## Constraints

- **Prefix-cache stability.** Custom context that changes every turn (e.g. `{{time}}`)
  busts the provider prefix cache. Stable context belongs in the system prompt
  (cached); per-turn content belongs at `.userTurn` so it does not bust the cached
  prefix. The editor flags per-turn blocks.
- **Token budget.** Custom context and instructions consume the same budget the
  history/compression math manages. Floor-cap custom context in `buildSystemPrompt`,
  mirroring how project context is floor-capped.

## Phasing

1. **Segment toggles** — wrap each built-in segment in `buildSystemPrompt`; wire
   session → profile → global resolution. Tests: each segment appears/disappears.
2. **Standing instructions** — append to rules; golden-prompt test.
3. **Custom blocks + placement + variable engine** — interpolator, injection points,
   floor cap. Tests: variable expansion, per-turn vs stable placement, budget cap.
4. **History control** — include/exclude summary, stateless mode, tail budget;
   reconcile with compression.
5. **UI** — context-recipe widget across the three surfaces + live preview.
6. **Observability** — prompt inspector showing final context, in/out segments,
   resolved source per segment, token delta.

## Open decisions

- Confirm the three-level model satisfies the "switch profile → gets that profile's
  default layout" expectation (yes, by design above).
- Confirm whether "entire context customizable" also includes suppressing the
  **tools index** segment and the **history** segment in the first pass, or defer
  those to a later phase.
- Whether per-session overrides should also pin the recipe into `Session.config`
  snapshots for shared/multi-contributor sessions.
