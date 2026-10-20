# Chrome redesign — implementation spec

Status: approved design, ready to implement. Design canvas (artboards + stickies): https://claude.ai/code/artifact/f49a98d4-670e-42b8-84de-793ff764026f — the canvas is the visual reference; this file is the contract. Where they disagree, this file wins.

Scope is the chrome only: sidebar, title bar, pane strip, composer frame, Files sidebar. The transcript, terminal and editor contents are unchanged.

Track the work as beads (`bd`), one per workstream below, in the order listed — WS1 and WS2 are prerequisites for WS3.

---

## Principles (apply everywhere)

1. **One home per action.** Nothing is reachable from two places except the Files sidebar toggle (title bar button + the sidebar's own close), which is the macOS convention.
2. **Type is four roles, not fourteen sizes.** See WS1. Weight means state (unread, emphasized); colour means status. Two weights only: regular and semibold.
3. **Status is one grammar.** Every sidebar row's second line reads `<glyph> <StatusWord> · <detail>`. Never `Ready` for two different things.
4. **Sidebars are not panes.** Left = sessions, right = Files. Both are full height, one per window, no split/close. Only the content area between them splits.
5. **Sandbox-level vs chat-level is visible.** Stop/Restart in the title bar act on the session's process in the sandbox and are grouped under a `Sandbox` label. Stopping a chat turn is the composer's Send button turned into Stop.
6. **Nothing wraps.** The pane strip is one line that condenses by rule (WS5). Chips never contain wrapping text.
7. **Opinionated, not configurable.** No new preferences. Density is the only tweak (WS3), and it's one setting.

---

## WS1 — Type scale (`Theme/Theme.swift`)

Add a type-role API and migrate every font call in `Sandshell/` to it. Today there are 14 point sizes (10, 10.5, 11, 11.5, 12, 12.5, 13, 13.5, 15, 16, 19) plus `.caption` ×84, `.callout` ×30, `.headline`, `.subheadline`, `.footnote`.

```swift
enum TypeRole { case title, body, bodyEmphasis, meta, code }

extension NSFont {
    static func role(_ r: TypeRole) -> NSFont   // AppKit
}
extension Font {
    static func role(_ r: TypeRole) -> Font     // SwiftUI
}
```

| Role | Spec | Use |
|---|---|---|
| `title` | 15 pt semibold | sidebar header, window title, Files sidebar header, inspector section heads |
| `body` | 13 pt regular | session names, menu items, buttons, composer, chat prose |
| `bodyEmphasis` | 13 pt semibold | unread session name, selected emphasis |
| `meta` | 11.5 pt regular | row sublines, crumb labels, timestamps, captions, toolbar labels |
| `code` | 11 pt SF Mono regular, `monospacedDigit` | paths, branch, diff counts, elapsed timers, token/cost readouts |

Rules:
- Delete every `systemFont(ofSize:)`, `.system(size:)`, `.caption`, `.callout`, `.headline`, `.subheadline`, `.footnote` call in `Sandshell/` (not `tests/`). Grep: `rg -n 'systemFont\(ofSize|\.system\(size|\.font\(\.(caption|callout|headline|subheadline|footnote)' Sandshell`. The only exceptions are the terminal (libghostty's own font) and the editor (`FileEditorController`).
- Symbol/icon sizes: 16 pt in `body` contexts, 12 pt in `meta` contexts. No 10 pt symbols (`SessionContextBar.ContextChip` uses 10 today).
- `Format.workTime` / `.ago` strings are always drawn in `code`.

Acceptance: the grep above returns nothing outside the two exceptions; app builds; `scripts/run-self-tests.sh --quick --only title-strip,panes` passes.

---

## WS2 — Session model: forks and names (`Workspace/WorkspaceState.swift`, `Sbx/WorkspaceController.swift`)

### Forks
`Session` gains two optional fields (optional so existing `state.json` decodes):

```swift
var forkedFrom: UUID?     // the source session
var forkedAt: Date?       // when forkChat ran
```

`WorkspaceController.forkChat(_:upTo:)` sets both on the new session. Sorting (sidebar `displayedSessionIDs`): a fork is grouped under its parent; the group sorts by the newest activity in the group; forks within a group sort oldest-first. A fork whose parent was closed/deleted sorts as a top-level session (keep `forkedFrom`; just don't nest).

### Name resolution
Today `autoName` overwrites the name with the **latest** prompt unless `isNamedByUser`. Change to:

```
displayName = isNamedByUser ? name
            : generatedName ?? firstPrompt ?? "New session"
```

- Add `var firstPrompt: String?` and `var generatedName: String?` to `Session`. `autoName` sets `firstPrompt` once (first non-empty prompt) and never again; it no longer overwrites `name` after that.
- `generatedName`: set once, after the first turn completes. Preferred source: Claude Code's own transcript title — Claude writes a `{"type":"summary","summary":"…"}` line into the session's `.jsonl` (what `claude --resume` lists). Verify this on a real transcript under `~/.claude/projects/` before relying on it; `ClaudeTranscriptTail` is the place to pick it up. If it isn't there for an agent (Codex, Gemini), leave `generatedName` nil and the first prompt stands.
- A fork's `firstPrompt` is its first *new* prompt after the fork point; until it has one, `displayName` is `"Fork of <parent displayName>"`.
- Rename (double-click / ⏎) sets `name` + `isNamedByUser = true`, as today. Clearing a rename reverts to the generated/first-prompt name.

Tests (Swift Testing, `tests/SandshellTests`): decode an old `state.json` without the new keys; `forkChat` sets `forkedFrom`; display-name resolution for each branch; `autoName` doesn't overwrite after the first prompt.

---

## WS3 — Sidebar (`UI/SidebarOutlineController.swift`, `SessionCellView`, `SubagentCellView`)

### Header
- Row 1: workspace mark (20 pt) · workspace name (`title`, truncating) with a ▾ chevron that opens the workspace switcher · a single **+** button (26×26, `#3F3631` fill) that opens today's "+ New Session" menu.
- Row 2: the search field (28 pt high, `#1F1A17` fill, placeholder "Search sessions", trailing `⌘F` hint in `code`). It is the **only** search entry point in the sidebar.
- Remove the header's 19 pt bold title style (→ `title`).

### Footer
Replace the four-item footer (gear, terminal, bug, "Search") with one full-width button: `● Sandbox · read-write  main` in `meta` (dot = sandbox state colour; branch in `code`). Click opens the workspace inspector / sandbox access popover. Settings stays on ⌘, and the app menu; Status Debug and the terminal diagnostics move to the Help menu.

### Row layout (comfortable density)
```
[badge 20] Title …………………………………………… [time, code, right-aligned]
           <glyph> StatusWord · detail
           “first instruction”              (only when the title isn't already it)
```
- Row padding 7 px vertical, 8 px horizontal; badge-to-text gap 9 px; corner radius 7.
- Badge: `AgentBadgeView` at 20 pt, radius 6. It is the only place the agent is identified; the word "Claude"/"Codex" no longer appears in the subline.
- Title: `body`; `bodyEmphasis` only while unread. Colour `sidebarFg` when live/unread/selected, else `sidebarFg` at 80 % (`#CFC5BC` on the default theme).
- Time (right, `code`): live elapsed `m:ss` while working (tick via the existing workspace clock); otherwise `Format.ago` of the last activity. Colour follows the status colour for working/needs-you, `sidebarFg` when unread, muted otherwise.
- Instruction line: `meta`, italic, muted (`#8E8278`), ellipsized; shown only in comfortable density and only when `displayName != firstPrompt`. In compact density it is the row's tooltip.
- Hover: the existing close × at the right of the title line. Nothing else is hover-only.

### Status line — the six states
| State | Glyph | Word | Detail | Colour (dark sidebar) |
|---|---|---|---|---|
| Needs you | 7 pt dot | `Needs you` | what it's waiting for ("permission to run tests", "a question") | `#F2B13A` |
| Working | 10 pt spinner (the only animated element in a row) | `Working` | model | `#E8845A` (`NSColor.sessionWorking`) |
| Finished, unread | 7 pt dot | `Finished` | `worked <Format.workTime> · <model>` | `#7FB3FF` + title semibold |
| Finished, seen | 7 pt dot at 45 % | `Finished` | `worked … · <model>` | muted `#A89C92` |
| Stopped | 7 pt dot | `Stopped` | `runtime.stoppedReason` (`exit 1`) | `#FF6B6B` |
| Idle (not run since launch) | 7 pt dot at 45 % | `Idle` | agent kind for non-Claude (`Shell`) | muted |

The status word is `meta` weight 500 in the status colour; the detail is `meta` muted. Replace the `WorkingSweepView` + status-dot pair with this; delete the `"Ready"`, `"New"` and `"N in background"` strings (background count moves to the subagents row).

### Order
Needs-you first, then working, then everything else by last activity (newest first). Forks nest under their parent (WS2); the group takes the position of its newest member.

### Forks and subagents (child rows)
- Fork rows: indented 24 px (17 px margin + 1 px rail `#4F443E` + 7 px padding), a branch glyph (11 pt, muted) before the title, same row anatomy otherwise.
- Subagents collapse to one child row directly under the parent: `▸ 4 subagents  <spinner> 2 running` (`meta`; running count in the working colour). Click toggles the existing subagent rows (`setShowsSubagents`). Replace the `› 4` affordance.

### Selection and open-pane marking
- Selected / focused pane: row fill `#3F3631`.
- Open in another pane (window has >1 pane): row fill `#322B27`.
- Background fills only — no left rail, no outline.

### Density
One app-level setting `SidebarDensity: comfortable | compact` (View menu). Compact: 40 px rows, no instruction line. Comfortable: 54 px rows. Default comfortable.

Acceptance: `subagents`, `fork`, `panes` self-test scenarios updated and green; a UI test asserts the six status strings appear for fixture sessions in the matching states; no row text ever wraps at the 220 px minimum sidebar width.

---

## WS4 — Title bar (`UI/MainWindowController.swift` toolbar)

Default items, left to right: `sidebarToggle` · `identity` · flexible space · **Sandbox group** · `filesToggle`.

- `identity`: the focused pane's session `displayName` in `title`, truncating. **No status, no timer, no subtitle** in the toolbar — the sidebar row carries status.
- **Sandbox group**: one bordered pill (`#D9CFC4` border, 8 pt radius, white fill) with three segments: a non-interactive leading label `⬡ Sandbox` (`meta`, `#F4F0EB` fill), then `■ Stop` (= `stopSession`, kills the session's process in the sandbox) and `↻ Restart` (= `restartSession`, today's `headerRestartClicked`). Labelled buttons, 12 pt medium, 28 pt high. Both disabled when no session is focused; the group hides when the window has no panes.
- `filesToggle`: labelled `Files` with the `sidebar.right` symbol; pressed state when the Files sidebar is shown. Shortcut ⇧⌥⌘0.
- Remove from the toolbar: `revealFolder` (lives in the folder crumb), `stopSession` as a bare icon, `chatToggle` (lives in the pane strip), `search` (lives in the sidebar field). Keep them in `toolbarAllowedItemIdentifiers` only if customization must stay; the spec prefers removing them.

---

## WS5 — Pane strip (`UI/TerminalStackController.swift` title strip, `UI/SessionContextBar.swift`)

The strip is 34 pt high, one line, `clipsToBounds`. Layout: `[crumbs — flexible, min 0] [controls — fixed]`.

### Crumbs (left), in priority order low → high
1. `sandbox` — ⬡ icon + sandbox name (`meta`). Opens the sandbox access popover (as today).
2. `folder` — folder icon + name. Click reveals in Finder (replaces the toolbar `revealFolder`).
3. `branch` — `main +99 −29` in `code` (`NSAttributedString.diffCounts`). Opens git/commits.
4. `name` — the session `displayName`, `meta` weight 500, full-contrast. **Only when the window has more than one pane.** Ellipsizes; never below 72 pt wide.
Separators are `›` in `#BDB2A8`.

### Condensing rule (by the strip's own width; implement as a layout pass, not autoresizing)
| Strip width | Change |
|---|---|
| < 560 pt | sandbox label hidden, icon stays (tooltip carries the name) |
| < 480 pt | folder label hidden, icon stays |
| < 410 pt | sandbox, folder, branch and their separators hidden; a `⋯` button appears before `name`, whose menu lists the three as items with their actions |
Controls never shrink, move or clip. The `name` crumb absorbs any remaining overflow with an ellipsis.

### Controls (right), fixed width, 24 pt high, 2 pt gaps
1. View switch — a **two-segment** control `Chat | Terminal` (26×20 segments, selected segment white with a 1 px shadow, `#ECE6DF` track). Shows the **current** view (today's single `chatModeButton` shows the destination, which reads backwards). Hidden for agents that don't support ACP, and for a terminal-only session.
2. Split right (⌘D), Split down (⇧⌘D), Close (⌥⌘W) — 14 pt symbols, always present.
Unfocused panes draw the whole strip at 40 % opacity (crumbs muted, controls dimmed); the focused pane's strip has the `#F0EAE3` fill. Hover restores full opacity.

### Removed from the strip
- `filesPaneButton` (Files is a sidebar, WS6).
- `ClaudeStatsView` (model/effort choosers, gauge, cost, ⓘ) → composer, WS7.
- `backgroundPill` → the sidebar's subagents row.

Acceptance: `title-strip` and `pane-buttons` self-tests updated; a test resizes a pane to 380 pt and asserts the `⋯` button is visible, all controls are inside the pane's bounds, and the strip's height is still 34 pt.

---

## WS6 — Files is the right sidebar (`UI/MainWindowController.swift`, `Files/FilesPaneController.swift`, `UI/PaneTreeController.swift`)

- Files is the trailing item of the window's `NSSplitViewController`, full height, 300–480 pt wide, one per window. It is **never** a pane in the pane tree: remove the Files-as-a-pane path (`TerminalStackController`'s Files surface, `emptyFilesButton`, "Show Files beside this pane").
- Header (52 pt, aligned with the title bar): `Files` in `title`, then `main · 6 changed` in `code`, then a close button (`sidebar.right` symbol) at the right. Below: the filter field; the tree; the editor (tabs) below the tree; the Commits section at the bottom. Background `#EFEBE6` with a 1 px `#DCD3C9` left border, so it reads as a sidebar, not a pane.
- Toggle: title-bar `Files` button, ⇧⌥⌘0, View ▸ Files. State saved per window (`filesVisibleKey` exists).

---

## WS7 — Composer (`Chat/ChatComposerView.swift`, `Chat/ChatSessionView.swift`)

- The input is a pill: white, 1 px `#DCD3C9` border, 24 pt radius, min height 48 pt, text inset 20 pt left / 14 pt right. No drop shadow.
- Inside the pill at the right: one 24 pt round button. Idle: Send (filled dark circle, arrow-up glyph). While a turn runs: **Stop** — a 2 pt dark ring with a filled 9 pt square. This is the chat-level stop (`chat.session.cancel()`); it is the only place it exists.
- Below the pill, plain text controls in `body` with no chip fills (hover highlight only), 10 pt side inset:
  - left: `+` (attach / @ files), MCP glyph with the server count (opens today's `mcpButton` popover).
  - right: model (weight 500, dark) · effort (muted) · approval mode (`Auto` / `Manual`) · the readout `ⓘ $0.47 · 38 %` in `code`, which opens today's Session details popover. These are `ChoicePopUp`s moved from `ClaudeStatsView`; the context gauge lives inside the details popover.
- A terminal pane has no composer and none of these controls.

---

## WS8 — Clean-up

- Delete `WINDOW_LAYOUT.md`'s header-bar and footer sections or rewrite them to match (the ASCII diagram still shows `📁|⏹|↻` and `⚙️ 🖥️ 🐛 📚`).
- `tests/ui/`: update the sidebar-footer and toolbar tests; add the pane-strip condensing test.
- `CHANGELOG.md`: one entry per workstream under the next version.

---

## Out of scope (explicitly)

- Any change to transcript rendering, the terminal, the editor, or Settings panes.
- New preferences beyond `SidebarDensity`.
- Theme changes: the colours above are the default theme's values; other themes map through `ThemeColors` as today.
