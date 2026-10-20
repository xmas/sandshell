# Sandshell Window Layout

The chrome as of the redesign in `CHROME-REDESIGN.md`: two sidebars, one per
side, and between them a content area that splits into panes.

## Structure

```
┌────────────────────┬───────────────────────────────────┬──────────────────┐
│ ☰                  │ Session name      [Sandbox|Stop|Restart] [Files]     │
├────────────────────┼───────────────────────────────────┼──────────────────┤
│ ▣ workspace ▾    + │ sandbox › folder › main +9 −2     │ Files  main · 6  │
│ [Search sessions ] │          [Chat|Terminal] ⊞ ⊟ ✕    │ [filter        ] │
│                    ├───────────────────────────────────┤ tree             │
│ ▣ Title       4:12 │                                   │                  │
│   ◌ Working · Opus │   transcript (chat) or terminal   │                  │
│   “instruction”    │                                   ├──────────────────┤
│   ⑂ Fork row       │                                   │ editor           │
│   ▸ 4 subagents    │ ╭───────────────────────────────╮ │                  │
│ ▣ Title         3m │ │ Message…                  (↑) │ │                  │
│   ● Finished · 12m │ ╰───────────────────────────────╯ ├──────────────────┤
│                    │ + MCP     model · effort · Auto ⓘ │ Commits          │
├────────────────────┤                                   │                  │
│ ● Sandbox · rw main│                                   │                  │
└────────────────────┴───────────────────────────────────┴──────────────────┘
```

## Title bar (`UI/MainWindowController.swift`, `UI/TitleBarViews.swift`)

Left to right: sidebar toggle · the focused pane's session name (title role,
truncating; no status, timer or subtitle) · flexible space · the **Sandbox**
group · **Files**.

- **Sandbox group** — one bordered pill: the focused session's sandbox by
  name (click it for the sandbox menu: Inspect…, Keep What Was Added as a
  Kit…, Stop/Start, Restart, Rebuild…), then **Stop** (**Start** while it's
  stopped) and **Rebuild** for the sandbox itself. Rebuild first looks for what
  was installed in it and offers to keep that as a workspace kit. A session's
  own Stop / Restart are in its pane strip; a chat's turn stops in its composer.
- **Files** — toggles the Files sidebar (⇧⌥⌘0, View ▸ Show Files); pressed
  while it's shown.

The toolbar is a fixed set (no customization).

## Session sidebar (`UI/SidebarOutlineController.swift`, `UI/SidebarRows.swift`)

- **Header** — workspace mark · workspace name with ▾ (workspace switcher) ·
  **+** (new session menu); below it the search field, the sidebar's only
  search (⌥⌘F focuses it).
- **Rows** — `[badge] Title …… time` / `<glyph> StatusWord · detail` /
  `“first instruction”` (comfortable density only, when the title isn't it).
  The badge is the only place the agent is named. Six states, one grammar
  (`UI/SidebarRowStatus.swift`): Needs you, Working (the only spinner),
  Finished (unread: blue dot, semibold title), Finished (seen), Stopped, Idle.
- **Order** — needs-you first, then working, then by last activity; forks nest
  under their parent on a rail; subagents and background tasks collapse into
  one `▸ N subagents · M running` child row.
- **Selection** — the focused pane's row has the selected fill; sessions open
  in other panes a quieter fill. Background fills only.
- **Density** — View ▸ Comfortable / Compact (the only sidebar setting).
- **Footer** — one button, `● Sandbox · read-write  main`: opens the sandbox
  access popover. Settings is ⌘,; Status Debug and the host terminal live in
  the Help menu.

## Content area (`UI/PaneTreeController.swift`)

Splits into panes (⌘D right, ⇧⌘D down, ⌥⌘W close; drag a session onto a pane
edge). Each pane is a `TerminalStackController` showing one session's chat or
terminal. Files is never a pane.

### Pane strip (`UI/PaneStrip.swift`)

One 34 pt line that never wraps: crumbs on the left (sandbox › folder ›
branch, plus the session name when the window has more than one pane),
controls on the right (Chat | Terminal; the session's Stop — terminals only — and Restart; split right, split down, close).
As the pane narrows: under 560 pt the sandbox label goes (icon stays), under
480 the folder label, under 410 sandbox/folder/branch fold into a ⋯ menu.
The controls never move or clip. Unfocused panes draw the strip at 40 %.

### Chat pane (`Chat/ChatSessionView.swift`, `Chat/ChatComposerView.swift`)

The transcript (centered, at most 800 pt wide), then the composer: a pill
input with one round button — Send, or Stop while a turn runs (the only
chat-turn stop). Below the pill: `+` (attach / @ files) and MCP on the left;
model · effort · approval mode · the cost/context readout (opens Session
details) on the right. A terminal pane has none of these.

### Status stack

Shown in a pane with nothing running yet: spinner and status ("Building…"),
the sandbox build log while a sandbox is made, Restart after a failure; an
empty pane offers New Session / Close.

## Files sidebar (`Files/FilesPaneController.swift`, `Files/FilesHeaderView.swift`)

The window's trailing split item: full height, 300–480 pt, one per window,
its visibility saved per window. Header `Files · main · 6 changed` and a
close button; then the filter, the tree, the editor (tabs) under the tree,
and Commits at the bottom.
