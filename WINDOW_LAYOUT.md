# Sandshell Window Layout

## Structure

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Sandshell Window                            │
├──────────────────────┬──────────────────────────────────────────────┤
│      SIDEBAR         │          DETAIL PANE                          │
├──────────────────────┼──────────────────────────────────────────────┤
│                      │                                               │
│   ┌──────────────┐   │  ┌──────────────────────────────────────┐   │
│   │    Header    │   │  │         HEADER BAR                   │   │
│   │ (icon+name)  │   │  ├──────────────────────────────────────┤   │
│   └──────────────┘   │  │ ☰│🔵│Session Name  Ready  |📁|⏹|↻│   │
│                      │  │ sidebar toggle, badge, name,          │   │
│   ┌──────────────┐   │  │ status, action buttons                │   │
│   │   Folder 1   │   │  └──────────────────────────────────────┘   │
│   │ ┌─ Session A │   │                                               │
│   │ ┌─ Session B │   │  ┌──────────────────────────────────────┐   │
│   │                  │  │         FRAME VIEW                   │   │
│   │   Folder 2   │   │  │  (terminal with rounded border)      │   │
│   │ ┌─ Session C │   │  │                                       │   │
│   │ ┌─ Session D │   │  │  ┌─ Title Strip ──────────────────┐ │   │
│   │                  │  │  │ bash — 80×24                    │ │   │
│   │   + New Folder   │  │  ├─────────────────────────────────┤ │   │
│   │                  │  │  │                                 │ │   │
│   └──────────────┘   │  │  │    HOST / TERMINAL              │ │   │
│                      │  │  │    (libghostty surface)         │ │   │
│   ┌──────────────┐   │  │  │                                 │ │   │
│   │    Footer    │   │  │  └─────────────────────────────────┘ │   │
│   │ ⚙️ 🖥️ 🐛 📚 │   │  └──────────────────────────────────────┘   │
│   │ settings    │   │                                               │
│   └──────────────┘   │  (or STATUS STACK when no session selected)  │
│                      │                                               │
└──────────────────────┴──────────────────────────────────────────────┘
```

## Sidebar

- **Header** — Folder icon, workspace name, dropdown chevron for workspace menu
- **Folder/Session List** — Hierarchical outline of folders and their sessions
  - Folders are expandable/collapsible
  - Sessions shown as children of folders
  - Each session shows agent badge, name, and status
- **Footer** — Four icon buttons
  - ⚙️ Settings (inspector)
  - 🖥️ Terminal (host shell)
  - 🐛 Console (logs)
  - 📚 History (conversation browser)

## Split Divider

- Vertical separator line between sidebar and detail pane
- Draggable to resize both panes

## Detail Pane

### Header Bar
The top bar showing the currently selected session's information and actions.

- **Sidebar Toggle** — ☰ icon to hide/show the sidebar
- **Agent Badge** — Colored circle (30×30) with agent icon
  - Claude: sparkles
  - Codex: code brackets
  - Shell: terminal
  - Others: appropriate symbols
- **Header Text** (vertical stack)
  - Session name (bold, 14.5pt)
  - Folder path (monospace, 11pt, secondary color)
- **Header Status** — Status indicator (Ready, Working, etc.) in secondary color
- **Header Actions** (right side) — Three icon buttons
  - 📁 Reveal in Finder
  - ⏹ Stop the session
  - ↻ Restart the session

### Frame View
The terminal container with rounded border (12pt radius) and border stroke.

- **Title Strip** — Dark bar at the top showing:
  - Terminal title (typically "bash" or shell name)
  - Dimensions (e.g., "80×24")
  - Monospace font, 10.5pt
- **Host** — The actual terminal content area
  - libghostty surface
  - Shows live output from the running session
  - Handles all terminal input/output

### Status Stack
Shown when no session is selected or a container is building.

- **Spinner** — Rotating indicator (hidden when not building)
- **Status Label** — Centered text
  - "Select a session" when idle
  - "Building…" when container is being created
  - "Rebuilding…" when container is being updated
- **Restart Button** — Shown only when session has exited
  - Allows user to restart a crashed/exited session
