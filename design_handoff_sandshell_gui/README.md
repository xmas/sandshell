# Handoff: Sandshell GUI — Projects → Sessions workspace + in-window agent terminals

## Overview

This is the **visual design spec** for the Sandshell macOS GUI (the native AppKit +
SwiftUI app in `xmas-sandshell/`). It documents the look, layout, and three theme
options we converged on for the GA "workspace-centric" product described in
`GA-PLAN.md` / `GA-IMPLEMENTATION.md`.

The app is one window = one workspace folder backed by a single `sbx` container. The
window is a **two-pane split**: a left **Projects → Sessions** source list, and a right
**detail pane** that hosts the selected session's live agent terminal (Claude Code,
Codex, or a plain shell). This handoff is the answer to "what should that window
*look* like" — it complements the functional plan, which already lives in the repo and
should be treated as authoritative for behavior.

## About the design files

The files in this bundle (`design/`) are **design references created in HTML** —
prototypes that show the intended look and behavior. They are **not** production code
to copy. The task is to recreate them in the existing Sandshell AppKit/SwiftUI codebase
using its established patterns (`NSSplitViewController`, `NSOutlineView` source list,
libghostty terminal hosting). Every value you need to build natively is written out in
this README; the HTML is just there to look at.

To view the prototypes: open `design/Sandshell Styles.dc.html` in a browser. It shows
all three themes side by side. Click any session in a sidebar to switch the active
terminal; the "time spent working" counter on a working session ticks live.

`design/explorations/` holds earlier directions we explored and **did not** pick
(developer-terminal layouts and a friendlier "office" framing) — included only for
context. Build from the converged design, not these.

## Fidelity

**High-fidelity.** Final colors, type, spacing, and layout. Recreate the chrome
pixel-faithfully with native AppKit views and the system materials noted below. The
terminal *content* shown in the mock is illustrative — real content comes from
libghostty; match only the surrounding chrome (header, status pill, terminal frame).

---

## The decision in one paragraph

Keep the **macOS source-list** idiom. Sidebar = collapsible **Project** group rows, each
containing **Session** rows and a trailing **"⊕ New Session"** row; a sticky header with
window/workspace identity + a settings affordance, a search field, and a footer
**"＋ New Project"** button. Detail pane = a **session header bar** (agent glyph, session
name, container · workdir, a status pill, and a live work-time pill) above a **framed
terminal** (title strip + scrolling mono transcript + an input affordance). Ship **three
fixed appearances** the user picks in settings: **Daylight** (light), **Workspace**
(dark sidebar + light detail/terminal), and **Midnight** (full dark, warm sand accent).
All three are the *same layout* — only the palette changes.

---

## Screens / Views

There is one screen (the main window). It has two regions.

### Region A — Sidebar (Projects → Sessions source list)

- **Purpose:** navigate projects and sessions; create projects/sessions; reflect each
  session's live status at a glance.
- **Width:** `296px`, fixed (`flex:none`). Full height, vertical flex column.
- **Background:** `var(--sidebar)`; right edge `1px solid var(--border)`.

Top to bottom:

1. **Header row** — `padding:13px 14px 11px`, horizontal flex, `gap:9px`, vertically
   centered.
   - Three macOS traffic-light dots (`12px` circles, `gap:8px`): `#ff5f57`, `#febc2e`,
     `#28c840`. *(In the native app these are the real window controls; the mock draws
     them only because it isn't a real window.)*
   - App mark: `26×26`, `border-radius:7px`, background `#1d63ed`, white `›_` glyph in
     mono `11px`/700.
   - Identity block (flex:1, min-width:0): workspace name **"Sandshell"** at `13.5px`/600,
     `letter-spacing:-.01em`, color `var(--sidebarfg)`; below it the root path
     **"~/Sandshell"** at `10px` mono, color `var(--sidebarmuted)`. Both truncate
     (ellipsis).
   - Settings button: `26×26`, `border-radius:7px`, background `var(--sidebarhover)`,
     gear glyph `14px`, color `var(--sidebarmuted)`. Opens the `⌘,` settings window.
2. **Search field** — `padding:0 16px 10px` wrapper; the field is `height:32px`,
   `border-radius:9px`, background `var(--sidebarhover)`, `padding:0 11px`, `gap:8px`,
   `12.5px` placeholder **"Search sessions"** in `var(--sidebarmuted)`, leading `⌕` glyph.
3. **Scroll area** (`flex:1`, `overflow-y:auto`, `padding:2px 8px 10px`) — the
   Project → Session tree (see below).
4. **Footer** — `padding:10px 14px`, top border `1px solid var(--border)`. A full-width
   **"＋ New Project"** button: `height:34px`, `border-radius:9px`, background
   `var(--sidebarhover)`, centered, `12.5px`/600, color `var(--sidebarfg)`, leading `+`
   glyph `14px`. Creates a `<root>/<name>/` subfolder.

#### Project group row
- `padding:12px 8px 5px`, flex, `gap:7px`, centered.
- Disclosure caret `▾` (`9px`, `var(--sidebarmuted)`).
- Folder glyph: a `13×11` rounded rect, `1.5px` border `var(--sidebarmuted)`, `border-top
  -width:3px`, `opacity:.65` (a small folder tab icon).
- Project name: `12px`/700, `letter-spacing:.01em`, color `var(--sidebarfg)`, truncates.
- Trailing count/badge: `margin-left:auto`, `10px` mono, `var(--sidebarmuted)`,
  `opacity:.7`. Shows the **session count**, or **"ro"** for a read-only project.

#### Session row
- `padding:7px 10px 7px 22px` (the `22px` left pad indents under the project),
  `border-radius:9px`, `gap:9px`, `margin-bottom:1px`, `cursor:pointer`.
- **Selected** background = `var(--sidebarsel)` — in light themes this is the theme's
  `--sel` tint; in any theme with a *dark* sidebar it is `rgba(255,255,255,.10)`.
  Unselected = transparent.
- **Agent badge:** `22×22`, `border-radius:6px`, white mono glyph `10px`/700, background
  = the agent's color (see Agents). Glyphs: Claude `✳`, Codex `</>`, Shell `›_`.
- **Text block** (flex:1, min-width:0):
  - Session name `12.5px`/500, `var(--sidebarfg)`, truncates. This is the *last thing the
    user typed* (per GA spec, sessions are auto-named from input).
  - Subline `10px`, `var(--sidebarmuted)`, truncates: **"`{Agent} · {Status}`"**, e.g.
    "Claude · Working".
- **Right rail** (flex:none, column, `align-items:flex-end`, `gap:4px`, `min-width:30px`):
  - **Status indicator**, top, in a `13px`-tall row:
    - *Working:* a `16×5` rounded track `rgba(22,163,74,.22)` with a `7px` `#16a34a` pill
      that sweeps left↔right (see Animations → `ptsweep`). This is the live "agent is
      working" affordance.
    - *Ready & unseen:* an `8px` amber dot `#e0962a`. (Shown only if the session is
      `ready` AND hasn't been viewed yet AND isn't the current selection — i.e. an
      "unread / needs you" dot that clears once seen.)
    - *Ready & seen / shell:* nothing.
  - **Work-time**, below (only when there is time to show): `9.5px` mono,
    `var(--sidebarmuted)`, `line-height:1`. Working sessions count **up live** from a
    base; ready sessions show a coarse final duration; shell sessions show nothing.

#### "⊕ New Session" row (one per project, always last)
- `padding:6px 10px 6px 22px`, `border-radius:9px`, `gap:7px`, color
  `var(--sidebarmuted)`, `11.5px`, leading `⊕` glyph `13px`. Execs the project's default
  agent at that project's workdir.

### Region B — Detail pane (active session terminal)

- **Purpose:** show and interact with the selected session's live terminal.
- `flex:1`, min-width:0, vertical flex column, background `var(--panel)`.

1. **Session header bar** — `height:58px`, bottom border `1px solid var(--border)`,
   `padding:0 18px`, flex, `gap:12px`, centered.
   - Agent badge `30×30`, `border-radius:9px`, white glyph `12px`/700, agent color.
   - Identity: session name `14.5px`/600, `letter-spacing:-.01em`, `var(--text)`,
     truncates; below, `11px` mono `var(--text2)`: **"`{container} · {workdir}`"** (e.g.
     "sandshell · ~/Sandshell/Sandshell").
   - **Status pill** (`margin-left:auto`): `padding:5px 11px`, `border-radius:999px`,
     background `var(--hover)`, `12px`/500, `var(--text2)`, `gap:7px`. Contains the same
     working-sweep bar OR a status dot (`var(--statuscolor)`), then the status label.
   - **Work-time pill** (only when time exists): `padding:5px 11px`,
     `border-radius:999px`, background `var(--hover)`, `12px` mono, `var(--text2)`,
     leading `◷` glyph.
2. **Terminal frame** — outer wrapper `flex:1`, `padding:14px 16px 16px`. Inner frame:
   full height, column, `border-radius:12px`, `overflow:hidden`, background
   `var(--termbg)`, `1px solid var(--border)`.
   - **Title strip:** `height:30px`, bottom border `1px solid var(--border)`,
     `padding:0 14px`, `10.5px` mono, `var(--termdim)`. Text =
     **"`{agent-or-bash} — {container}`"** (e.g. "claude — sandshell", "bash — my-work").
   - **Transcript:** `flex:1`, `overflow-y:auto`, `padding:14px 16px`, mono `12.5px`,
     `line-height:1.65`, `white-space:pre-wrap`. Each line colored by role (see Terminal
     line colors). In the native app this whole region is the **libghostty surface** —
     do not reimplement; just frame it. The mock's line styling is a guide for how the
     terminal *theme* should be configured (bg, fg, dim, accent, green, red).
   - **Input affordance** (illustrative, libghostty owns real input):
     - Agent sessions: a boxed prompt — `margin-top:12px`, `1px solid var(--termaccent)`,
       `border-radius:9px`, `padding:9px 12px`, `gap:8px`, `var(--termdim)`: a
       `var(--termaccent)` `›`, placeholder ("Reply to Claude…" / "Send a message to
       Codex…"), and a right-aligned `10px` "⏎ to send".
     - Shell sessions: a caret line — `❯` in `var(--termaccent)` + an `8×15`
       `var(--termaccent)` block cursor that blinks (`ptblink`).

---

## Themes

Three fixed appearances, selectable in Settings → Appearance. **Same layout, different
palette.** Each is expressed as a set of CSS variables in the mock; map them to your
`NSColor` / `NSAppearance` setup. "Daylight" = `light` base, no overrides. "Workspace" =
`light` base + a dark sidebar block. "Midnight" = `dark` base + a warm sand accent.

### Base palettes

**Light base** (Daylight & Workspace detail area)

| Token | Value | Used for |
|---|---|---|
| `bg` | `#eef0f4` | window backing |
| `panel` / `sidebar` | `#ffffff` | detail pane / sidebar surface |
| `sidebarfg` | `#1a1d24` | sidebar primary text |
| `sidebarmuted` | `#8b91a0` | sidebar secondary text/icons |
| `sidebarhover` | `#f2f3f7` | sidebar control fills |
| `text` | `#1a1d24` | detail primary text |
| `text2` | `#5b6170` | detail secondary text |
| `text3` | `#9aa1ad` | detail tertiary |
| `border` | `#e7e9ef` | hairlines |
| `hover` | `#f4f5f8` | pill fills |
| `sel` | `#e7eefe` | selected-row tint (light sidebar) |
| `accent` | `#1d63ed` | Docker Ocean accent |
| `accentfg` | `#ffffff` | text on accent |
| `termbg` | `#f7f8fb` | terminal surface |
| `termtext` | `#1f2430` | terminal default text |
| `termdim` | `#9098a6` | terminal dim/comment |
| `termaccent` | `#1d63ed` | prompt/accent in terminal |
| `termgreen` | `#1a7f4b` | success lines |
| `termred` | `#c0392b` | error lines |

**Dark base** (Midnight, and the dark sidebar block)

| Token | Value |
|---|---|
| `bg` / `panel` | `#0c0d11` |
| `sidebar` | `#0f1116` |
| `sidebarfg` | `#e6e8ee` |
| `sidebarmuted` | `#7a8190` |
| `sidebarhover` | `rgba(255,255,255,.06)` |
| `text` | `#e6e8ee` |
| `text2` | `#9aa1ad` |
| `text3` | `#6b7280` |
| `border` | `rgba(255,255,255,.08)` |
| `hover` | `rgba(255,255,255,.05)` |
| `sel` | `rgba(79,139,255,.18)` |
| `accent` | `#4f8bff` |
| `accentfg` | `#ffffff` |
| `termbg` | `#15171d` |
| `termtext` | `#cdd3dc` |
| `termdim` | `#6b7480` |
| `termaccent` | `#6ea0ff` |
| `termgreen` | `#46c08a` |
| `termred` | `#ff7b72` |

### Per-theme overrides

- **01 · Daylight** — light base, no overrides. Light & clean, Docker Ocean accent,
  light terminal. *(Default.)*
- **02 · Workspace** — light base for the detail/terminal, but the **sidebar is dark**:
  `sidebar:#1b1822`, `sidebarfg:#d8d4e0`, `sidebarmuted:#8b8498`,
  `sidebarhover:rgba(255,255,255,.08)`. (Slack-style: dark nav, light work area.) In dark
  mode this variant's sidebar deepens to `#141019`.
- **03 · Midnight** — dark base + **warm sand accent**: `accent:#f0b148`,
  `accentfg:#241803`, `sel:rgba(240,177,72,.16)`, `termaccent:#f0b148`,
  `termgreen:#7bd88f`. (In its light form the accent is `#cf8a24` on `#fbeed6`.) This is
  the "whale-in-sand" identity look.

> **Selected-row rule:** whenever the sidebar is dark (Workspace, or any dark theme),
> the selected session row uses `rgba(255,255,255,.10)` instead of the palette `sel`.

---

## Agents

| Agent | Label | Glyph | Color |
|---|---|---|---|
| Claude (Claude Code) | Claude | `✳` | `#d97757` |
| Codex (OpenAI Codex) | Codex | `</>` | `#10a37f` |
| Shell (plain bash/zsh) | Shell | `›_` | `#64748b` |

Same agent → same glyph/color everywhere (sidebar badge, header badge). GA initial scope
is **claude + codex**; shell is the fallback session type.

## Status model

| Status | Label | Indicator |
|---|---|---|
| `working` | Working | green sweep bar `#16a34a` (animated) |
| `ready` | Ready | amber `#e0962a` — shown as the unread dot until seen |

A session is **working** while the agent is running, **ready** otherwise. The amber dot
is an *unread* affordance: it appears on a `ready` session only until the user selects /
views it, then clears.

## Terminal line colors (libghostty theme guidance)

Map these to the ghostty palette per theme (values shown are the light/Daylight set; use
the dark base for Midnight):

| Role | Color token | Weight |
|---|---|---|
| system / meta (`✻ Claude Code …`) | `termdim` | 400 |
| user input (`› …`) | `termtext` | 600 |
| bullet / action (`● …`) | `termaccent` | 600 |
| tool result (`⎿ …`) | `termdim` | 400 |
| success (`** BUILD SUCCEEDED **`) | `termgreen` | 400 |
| error | `termred` | 400 |
| shell prompt line | `termaccent` | 600 |
| shell output | `termtext` | 400 |
| dim / thinking | `termdim` | 400 |

---

## Interactions & behavior

- **Select a session** → its terminal becomes the visible one in the detail pane.
  Selecting a `ready+unread` session clears its amber dot. (Native: sidebar selection
  drives which retained terminal `NSView` is shown — toggle `isHidden`, never re-parent.)
- **⊕ New Session / ＋ New Project** → create flows per `GA-PLAN.md` §3–4.
- **Live work-time:** working sessions increment a `Working …` timer once per second;
  formatted `s` → `m s` → `h mm`. Ready sessions show a coarse final duration. Shell
  sessions show none.
- **Keybindings** (from GA plan): `⌘⇧[` / `⌘⇧]` cycle sessions; `⌘W` close session;
  `⌘,` settings.

## Animations

House motion is **200ms `cubic-bezier(0.22, 1, 0.36, 1)` ease-out, fades + short
translates only** (per the design system). The mock uses three named keyframes:

- `ptsweep` — the working bar: a `7px` pill animates `left:0 → 9px`, `.85s
  ease-in-out infinite alternate`.
- `ptblink` — shell block cursor: opacity 1→0 step, `1.05s steps(1) infinite`.
- (`ptpulse`, `ptspin` defined but unused in the converged design.)

No bounces, no parallax, no entrance stagger > 40ms/item.

---

## State management

Per the GA plan, the window binds to a `Workspace` (root path + single `sbx` container).
UI state the design relies on:

- **Selected session** per window (drives the detail pane).
- **Per-session status** (`working` / `ready`) — derived from agent/container state.
- **Seen set** — which `ready` sessions have been viewed (clears the unread dot).
- **Per-session work-time** — base seconds + live tick while working.
- **Active appearance** — Daylight / Workspace / Midnight (workspace- or app-scoped pref).

Project order, session list/order/names, expanded state persist to
`<root>/.sandshell/state.json` (see GA-PLAN §4).

---

## Design tokens (summary)

- **Type:** primary sans **IBM Plex Sans** (Docker brand sans; substitute for the native
  app is the system font / SF Pro — match weights). Mono **JetBrains Mono** (the native
  terminal/labels already use SF Mono — keep SF Mono for the libghostty surface; use a
  mono for the small metadata labels). Key sizes: window title `13.5px`/600; session name
  `12.5–14.5px`/500–600; sublines `10–11px`; terminal `12.5px`/1.65; tiny mono metadata
  `9.5–10.5px`.
- **Radii:** app/agent badges `6–9px`; pills/search/buttons `9px`; terminal frame `12px`;
  status pills fully rounded (`999px`); traffic lights `999px`.
- **Spacing rhythm:** 4 / 7 / 9 / 11 / 14 / 16 / 18 px in chrome; sidebar width `296px`;
  header bar `58px`; terminal title strip `30px`.
- **Borders:** `1px` hairlines, `var(--border)` per theme.
- **Shadows:** none on the in-window chrome (flat, per design system).
- **Colors:** full per-theme tables above. Docker Ocean `#1d63ed` is the light accent.

---

## Mapping to the existing codebase

The repo's `GA-PLAN.md` §12 reuse/retire map already names the files. This design lands on
those views as follows:

| This design | Native target (from GA plan) |
|---|---|
| Two-pane window | `UI/MainWindowController.swift` (`NSSplitViewController`, sidebar \| detail) |
| Sidebar source list (project groups, session rows, New Session/Project) | `UI/SidebarOutlineController.swift` (`NSOutlineView`, source-list style) — replaces SwiftUI `SidebarView` |
| Session header bar + framed terminal | `UI/TerminalStackController.swift` + `Terminal/TerminalSession.swift` (in-window host; one retained `NSView`/session, toggle `isHidden`) |
| Agent badge / glyph / color | `Sbx/Models.swift` `AgentKind` (extend with display glyph+color) |
| Status (working/ready) + work-time | `Sbx/WorkspaceController` session state + a per-session timer |
| Appearance picker (Daylight/Workspace/Midnight) | `UI/Settings/SettingsPanes.swift` Appearance pane; apply via `NSAppearance` + a theme color set |
| Terminal palette per theme | ghostty config (`termbg/termtext/termdim/termaccent/termgreen/termred`) |

Preserve all locked invariants from `GA-IMPLEMENTATION.md` §1 (not App-Sandboxed,
`PathFixer`, temp-script `sbx exec` launch, `UIDesignRequiresCompatibility` Sequoia look,
macOS 14 target).

## Assets

- No image assets. All glyphs are unicode placeholders (`✳ </> ›_ ⊕ ◷ ❯`) — in the native
  app, prefer **SF Symbols** (e.g. `plus`, `clock`, `gearshape`, `magnifyingglass`) and
  the agent brand marks where available; keep the agent **colors** above.
- Traffic-light dots are the real `NSWindow` controls natively (don't draw them).
- Fonts: IBM Plex Sans + JetBrains Mono (design-system fonts) — the running app should use
  its existing SF Pro / SF Mono stack; these are just what the mock renders with.

## Files in this bundle

```
design/
  Sandshell Styles.dc.html     ← THE decided design: 3 themes side by side (open this)
  SandshellApp.dc.html         ← the single-window component the styles file imports
  colors_and_type.css          ← design-system color/type variables the mocks read
  support.js                   ← runtime that renders the .dc.html prototypes
  explorations/                ← NOT chosen — earlier directions, for context only
    Terminal Sandbox Styles.dc.html   (Eclipse / Aurora / Linen / Dispatch)
    Office Sandbox Styles.dc.html     (friendlier "office" framing)
    OfficeApp.dc.html
```

In the repo, the authoritative behavior docs are `xmas-sandshell/GA-PLAN.md` and
`xmas-sandshell/GA-IMPLEMENTATION.md`; `xmas-sandshell/CLAUDE.md` carries build/run and
invariants. This README is the **visual** layer on top of those.
