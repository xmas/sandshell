# Sandshell GA — Vision & Phase Overview

> **For the executable, multi-session build plan see [`GA-IMPLEMENTATION.md`](GA-IMPLEMENTATION.md).**
> That file is authoritative and carries verified `sbx` CLI facts that correct a couple of
> assumptions here (notably: there is **no `sbx mcp`** command — MCP is `--static-mcp` at
> create time, so MCP changes require a rebuild). This file remains the higher-level vision.

Status: draft for review. This plan turns Milestone 1 (a many-sandbox manager with
terminals in separate windows) into the GA product: a **workspace-centric** app where
each window is one git-tracked folder backed by a single `sbx` container, organized as
Projects → Sessions.

---

## 1. The mental-model shift

| | Milestone 1 (today) | GA (target) |
|---|---|---|
| What a window is | A manager listing N sandboxes | **One workspace = one root folder = one `sbx` container** |
| Sidebar | Flat list of sandboxes | **Tree: Project → Sessions**, reorderable, renamable |
| Terminals | Separate `NSWindow`s, native tabbing | **In-window**, one per Session, selected from sidebar |
| Sandbox lifecycle | User starts/stops/removes each | One container per root; **rebuilt automatically** when mounts change |
| Persistence | None | Git-tracked root + `.sandshell/` metadata + app prefs |
| Settings | None | `⌘,` settings window with icon-tab panes |
| MCP / context / archive | None | MCP UI, auto-archive → `PROJECT.md`, auto-commit |

### Core entities (new)

- **Workspace** — a root folder (default `~/Sandshell`, user can pick e.g. `~/Dropbox/...`).
  One window is bound to one Workspace. Backed by exactly one `sbx` container.
- **Project** — a *direct subfolder* of the workspace root. Has a display name (= folder
  name), a stored sidebar order, and a `PROJECT.md`. Default project **"My Work"**
  (`<root>/My Work/`). Adding a project creates a subfolder; renaming renames it.
- **Session** — a running agent/terminal inside the container, with workdir =
  `<project subfolder>`. Named after the last thing the user typed. Belongs to one
  Project; has stored order. Each Project always shows a **"＋ New Session"** row.
- **MountPolicy** — the rule set producing the container's mounts (see §3).
- **McpServer** — an MCP entry managed via `sbx mcp …`.

### Assumptions to confirm (see §11)
- One container per window/root; multiple windows ⇒ multiple roots/containers allowed.
- The workspace root is mounted **read-write**; other non-dot `$HOME` subfolders **read-only**.
- "Sessions are tabs" and "sidebar sessions" are the *same* objects — sidebar selection
  drives which in-window terminal is visible; `⌘[`/`⌘]` cycle them.

---

## 2. Phasing overview

Each phase is independently buildable/testable and ends with a working app.

0. Domain model + persistence foundations
1. Single-`sbx`-per-window lifecycle + mount policy + rebuild-on-change
2. Project/Session sidebar tree (reorder, rename, new/close)
3. In-window terminal sessions (hosting, tab nav, naming, close)
4. Settings window (icon-tab scaffold + General/Folders/Mounts panes)
5. MCP management UI
6. Git engine (init, watch, attributed auto-commit, history)
7. Auto-archive + `PROJECT.md` (timer, capture, merge, session init)
8. Polish: keybindings, menu, appearance prefs, remote linking

---

## 3. Phase 1 — Workspace + single-container lifecycle & mount policy

**Goal:** binding a window to a root folder spins up (or attaches to) exactly one `sbx`
container with the correct mounts; changing mounts rebuilds it.

### Mount policy (default)
Computed at create time from `$HOME`:
- **Root workspace folder** → read-write.
- **Each non-dot subfolder of `$HOME`** → read-only (reference access).
- **Dot-folders** → excluded by default, **except** `.agents .claude .codex`
  → read-write (agent kit configs/state/auth). *(Initial GA scope is claude + codex; the
  spec's full rw set also lists `.copilot .cursor`, added when those agents are scoped in.)*
- **User extras** → additional folders the user adds, each rw or ro.

`MountPolicy` produces an ordered list of `path` / `path:ro` mount specs. This extends the
existing positional-mount approach in `SbxClient.create` (today it hardcodes `~/.claude`,
`~/.codex`, etc.) into a computed set.

### Rebuild-on-change
"If folder/folders are added or modified, the sandbox is taken down and rebuilt."
- Hash the resolved mount set + agent kit set. Store the hash with the container.
- On any mount/policy edit: `sbx stop` → `sbx rm -f` → `sbx create …` with new mounts,
  preserving the container name and reopening prior sessions where possible.
- Guard with a confirmation ("This will restart all sessions") since it kills running work.

### Kits
**Initial GA scope: claude + codex.** Container ships those two kits to start (the spec's
full set adds copilot + gemini, deferred). Confirm whether kits are `sbx create --kit …`
(multiple) or a base image; verify exact flags via the `sbx` skill / `sbx create --help`.

### Code changes
- New `Workspace.swift` (root path, container name, policy, kit set).
- New `MountPolicy.swift` (compute mounts from `$HOME`, apply user extras).
- `SbxClient`: add `mcp` subcommands (Phase 5), parameterize `create` mounts from policy,
  add `rebuild`. Reuse existing actor/`Process`/`clean` patterns.
- `SandboxStore` → renamed/refocused as **`WorkspaceController`** (`@MainActor`,
  `ObservableObject`): owns the single container's state, replaces 2s `sbx ls --json`
  polling with targeted status checks for *this* container.
- `MainWindowController` binds to a `Workspace`; "New Window" prompts for a root folder
  (default `~/Sandshell`, create if missing).

---

## 4. Phase 2 — Project / Session sidebar tree

**Goal:** the vertical sidebar becomes a two-level tree with reordering, renaming,
new-session rows, and close affordances.

### Recommendation: NSOutlineView-backed sidebar
SwiftUI `List`+`OutlineGroup`+`.onMove` struggles with: two independent reorder scopes
(projects vs sessions-within-project), inline rename, per-row close (X), and drag fidelity.
An `NSOutlineView` (source-list style) wrapped in an `NSViewControllerRepresentable` / used
directly in the split gives native drag-reorder, inline editing, and context menus. This
replaces today's SwiftUI `SidebarView`.

### Behaviors
- **Tree:** Project rows (expandable) → Session rows + a trailing **"＋ New Session"** row.
- **Projects:** add (creates `<root>/<name>/`), rename (renames folder), reorder
  (persisted order, FS-independent), delete (with confirmation; archive vs delete folder TBD).
- **Sessions:** reorder within project; **close via `⌘W` or hover-X**; auto-named from the
  last input typed (truncated). New session = exec the project's default agent at that workdir.
- **Selection** drives the visible in-window terminal (Phase 3).

### Persistence
Project order, session list/order/names, expanded state → `<root>/.sandshell/state.json`
(git-ignored; volatile). Project identity = subfolder; "My Work" auto-created on first open.

### Code changes
- New `SidebarOutlineController.swift` (NSOutlineView data source/delegate, drag-reorder,
  rename, context menus).
- New `ProjectStore.swift` / `SessionStore.swift` (or one `WorkspaceState`), persisted to
  `.sandshell/state.json`.
- Retire flat `SidebarView` sandbox list; keep create-sheet bits where reusable.

---

## 5. Phase 3 — In-window terminal sessions

**Goal:** the detail pane hosts the selected Session's live terminal; sessions stay alive in
the background; `⌘[`/`⌘]` cycle them.

### Hosting approach
Reuse `TerminalSession` (one libghostty `TerminalController` + `AppTerminalView` per
session, `.exec` backend, temp-script `command` from `SbxCommand`). For in-window display:
- Keep **one container `NSView` per session**, all retained; show the active one, hide the
  rest (avoid re-parenting — the prior in-window attempt blanked surfaces on re-add; the fix
  is to never re-parent, only toggle `isHidden`/membership in a stable container stack).
- Detail area = a custom tab/stack host driven by sidebar selection, not separate `NSWindow`s.
- `SbxCommand` already builds `sbx exec -it -w <workdir> <name> env … bash -c '… exec <agent>'`;
  set `-w` to the Project subfolder per session.

### Session naming + input capture
- Capture typed input (first prompt / last command) to name the session. libghostty exposes
  surface I/O — confirm the hook (title callback or PTY echo). Fallback: name from the first
  line submitted, rename on subsequent commands ("named based on the last thing you typed").
- This same input capture feeds command attribution for git commits (Phase 6) and archive.

### Code changes
- New `SessionHostView`/`TerminalStackController` for in-window swapping.
- `TerminalSession`: expose title/input stream; per-session workdir already supported.
- Retire `TerminalWindowController`/`TerminalLauncher` separate-window flow (or keep a
  "tear out to window" later).

---

## 6. Phase 4 — Settings window (`⌘,`)

**Goal:** standard macOS settings window with a row of colored icon "tabs".

- `NSWindow` with `NSToolbar` in `.preference` style (selectable items, SF Symbols with
  tint), swapping content view controllers per pane — the classic System-Settings look.
- Panes (initial): **General** (root folder, default agent, archive interval, polling),
  **Folders/Mounts** (policy + user extras, rw/ro, triggers rebuild), **MCP** (Phase 5),
  **Git/Remote** (Phase 6), **Appearance** (terminal font/theme — today hardcoded SF Mono 13).
- All workspace config lives here; persisted to `<root>/.sandshell/config.json` (workspace
  scoped) + `UserDefaults` for app-global UI (window frame, fonts).

### Code changes
- New `SettingsWindowController.swift` + `Settings/*Pane.swift` (SwiftUI panes in hosting
  controllers).
- Menu: add **Settings… (`⌘,`)** to the app menu in `MainMenu.swift`.

---

## 7. Phase 5 — MCP management UI

**Goal:** a UI for all MCP servers via `sbx mcp …`, with `SBX_MCP_URL` defaulting to
`https://gateway.docker.com` (editable).

- Settings "MCP" pane: list / add / remove servers. Verify exact CLI via `sbx mcp --help`
  (expected `sbx mcp add`, `sbx mcp ls`, `sbx mcp rm`).
- `SBX_MCP_URL`: surface as an editable field; default `https://gateway.docker.com`; inject
  into container env (and into the `env …` block in `SbxCommand`). Changing it may require
  rebuild — decide rebuild-vs-live (§11).
- `SbxClient`: add `mcpAdd/mcpList/mcpRemove`.

---

## 8. Phase 6 — Git engine

**Goal:** the entire workspace is under git; file edits become attributed commits
automatically; optional remote.

- **Init:** on first open of a root, `git init` (unless already a repo); seed `.gitignore`
  (ignore `.sandshell/state.json`, caches; **track** `PROJECT.md`). Default **local-only**;
  Settings → Git/Remote can add/link an `origin` and toggle push.
- **Watch:** `FSEventStream` (or `DispatchSource`) on the root; **debounce** change bursts.
- **Attributed commits:** the literal "every single file edit = one commit" is too noisy;
  pragmatic interpretation = one commit per debounced burst, attributed to the **active
  session** and **last command**. Encode metadata as git trailers:
  ```
  <summary>

  Sandshell-Project: My Work
  Sandshell-Session: <session name>
  Sandshell-Command: <last command>
  ```
  (Author date/time come for free.) A History view can filter by trailer.
- **Attribution source:** the input-capture from Phase 3 maps file-change bursts to whichever
  session is active / last issued a command.

### Code changes
- New `GitEngine.swift` (libgit2 via SwiftPM, or shell `git` via `Process` — recommend shell
  `git` first for simplicity, mirroring `SbxClient`).
- New `FileWatcher.swift` (FSEvents wrapper, debounce).
- Optional `HistoryView` (Phase 8 polish) querying `git log --grep=Sandshell-Session`.

---

## 9. Phase 7 — Auto-archive + `PROJECT.md`

**Goal:** every N minutes (default 5, configurable), capture each active session's state and
maintain a per-project `PROJECT.md`; new sessions initialize from it.

**Decision (resolved):** archive **from per-agent state files**, not by injecting prompts
into the live conversation. This is non-disruptive and works because the agent config
dot-folders are bind-mounted read-write — whatever the agent writes inside the container
appears on the host for Sandshell to read.

### Per-agent state-file collectors (initial GA scope: claude + codex)
Both verified on this machine.
- **Claude Code** — `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`. Dir name =
  the **container-side** workdir with `/`→`-` (e.g. `/work/My Work` → `-work-My-Work`), so
  the collector maps using the workdir Sandshell passed to `-w`, **not** the host path.
  Each JSONL line carries `cwd`, `timestamp`, `sessionId`, `message`, and — usefully —
  `lastPrompt` and `aiTitle`. Read newest transcript for the session's cwd; extract user
  prompts + assistant turns since the last archive watermark.
- **Codex** — `~/.codex/sessions/YYYY/MM/DD/<rollout>.jsonl` (date-bucketed) plus
  `~/.codex/history.jsonl`; select the rollout whose `cwd` matches the session workdir,
  most recent by timestamp.

Deferred (out of initial scope): **Copilot** (session-transcript location unknown) and
**Gemini** (no rw mount in default policy, no known state store) — see §11 (4a/4b).

This is a clean adapter seam: one `SessionStateCollector` per agent, keyed by agent kind +
container workdir. Bonus reuse: Claude's `aiTitle`/`lastPrompt` can feed session naming
(§5/Phase 3) directly, with PTY input-capture as the generic fallback.

- **Watermark:** track last-archived timestamp per session so each pass merges only new
  turns (idempotent, cheap).
- **Merge:** combine new context with existing `PROJECT.md` and write
  `<root>/<project>/PROJECT.md`; commit via the git engine (attributed to the session).
- **Session init:** opening a **New Session** reads the project's `PROJECT.md` and seeds the
  agent so a new session resumes where the project left off.

### Code changes
- New `ArchiveScheduler.swift` (timer, throttling, per-session watermarks).
- New `SessionStateCollector` protocol + `ClaudeCollector` / `CodexCollector`. The protocol
  is the extension point for Copilot/Gemini later — no other code changes when adding agents.
- New `ProjectDoc.swift` (read/merge/write `PROJECT.md`).

---

## 10. Phase 8 — Polish

- **Keybindings:** `⌘[` / `⌘]` previous/next session tab; `⌘⌥↑` / `⌘⌥↓` move selection in
  sidebar; `⌘W` close session; `⌘,` settings; New Project / New Session / New Window items.
  Wire in `MainMenu.swift` + first-responder actions.
- **Appearance:** terminal font/theme prefs (replace hardcoded SF Mono 13 / block cursor).
- **Remote:** add/link git remote, push toggle, status indicator.
- **History view:** browse commits by Project/Session/Command/time.
- Keep `UIDesignRequiresCompatibility` (Sequoia look) and the non-App-Sandbox + PATH-fix
  invariants intact.

---

## 11. Open questions / decisions needed

1. ~~**Multiple windows/roots**~~ — **Resolved: yes.** Each window owns its own root +
   container. Settings/MCP/policy are workspace-scoped per root.
2. **Root mount r/w:** is the workspace root read-write while the rest of `$HOME` is
   read-only? (Plan assumes yes.)
3. **Kits:** exact `sbx` flag for shipping claude + codex together — one base image or
   repeated `--kit`? (copilot/gemini deferred.)
4. ~~**Archive directive**~~ — **Resolved: read per-agent state files** (see §9).
   **Initial GA scope is claude + codex only.** Deferred follow-ups (out of scope now):
   - **(4a) Copilot** — session-transcript location unknown; investigate when scoped in.
   - **(4b) Gemini** — needs `.gemini` added to rw mounts + its session store located when
     scoped in.
5. **Commit granularity:** confirm debounced-burst commits (recommended) vs. literal
   per-edit commits.
6. **`SBX_MCP_URL` change:** does changing it require a container rebuild or can it apply to
   new sessions only?
7. **Project delete semantics:** delete the subfolder, or just hide from sidebar?
8. **`.sandshell/` in git:** confirm we git-ignore volatile state and only track `PROJECT.md`.

---

## 12. Reuse / retire map (existing code)

| File | GA fate |
|---|---|
| `App/AppDelegate.swift` | Keep; add Settings + New Window; per-window root binding |
| `App/MainMenu.swift` | Extend (settings, tab/sidebar nav, new project/session) |
| `Sbx/PathFixer.swift` | **Keep as-is** (PATH fix + sbx resolution invariant) |
| `Sbx/SbxClient.swift` | Extend: policy-driven mounts, `mcp …`, `rebuild` |
| `Sbx/Models.swift` | Add Workspace/Project/Session/MountPolicy/McpServer |
| `Sbx/SandboxStore.swift` | Refactor → `WorkspaceController` (single container) |
| `UI/MainWindowController.swift` | Keep split; bind to Workspace; host session stack |
| `UI/SidebarView.swift` | Replace with NSOutlineView tree |
| `UI/DetailView.swift` | Replace with in-window session host |
| `UI/CreateSandboxView.swift` | Repurpose bits into Settings/Folders + New Window |
| `Terminal/SbxCommand.swift` | Keep; per-session `-w`, inject `SBX_MCP_URL` |
| `Terminal/TerminalSession.swift` | Keep; expose title/input; in-window hosting |
| `Terminal/TerminalWindowController.swift` | Retire (or later "tear out to window") |
| `Terminal/TerminalLauncher.swift` | Retire / fold into session host |
| — | New: `GitEngine`, `FileWatcher`, `ArchiveScheduler`, `ProjectDoc`, `SettingsWindowController` + panes, `SidebarOutlineController`, `WorkspaceState` |

---

## 13. Suggested build order (PR-sized)

1. Workspace binding + `MountPolicy` + single-container create/rebuild (Phase 1).
2. NSOutlineView sidebar with projects/sessions, persistence (Phase 2).
3. In-window terminal hosting + session naming + close/nav (Phase 3).
4. Settings window scaffold + General/Folders panes wired to rebuild (Phase 4).
5. MCP pane + `SBX_MCP_URL` (Phase 5).
6. GitEngine + FileWatcher + attributed commits (Phase 6).
7. ArchiveScheduler + `PROJECT.md` + session init (Phase 7).
8. Keybindings, appearance, remote, history (Phase 8).
