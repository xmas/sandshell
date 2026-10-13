# Sandshell GA — Executable Implementation Plan

This is the **authoritative, self-contained, multi-session** build plan for Sandshell GA.
Vision/summary lives in `GA-PLAN.md`; where the two differ, **this file wins** (it carries
verified `sbx` CLI facts that correct earlier assumptions).

Initial scope: **claude + codex agents only**. Copilot/Gemini deferred.

---

## 0. How to use this document (resumption protocol)

Work proceeds phase by phase. Each phase has an **Objective**, a **Task checklist**, the
**Files** it touches, and **Done-when** acceptance criteria.

At the **start of a session:**
1. Read §1 (locked decisions) and §2 (open spikes) so you don't re-litigate them.
2. Read the **Progress Log** (§12, at the bottom) — it is the source of truth for what's
   done and what's next. The last entry names the next task.
3. Pick up the first unchecked `[ ]` task in the current phase.

At the **end of a session:** append a Progress Log entry — date, what landed, what's next,
any new decisions or spikes discovered. Check off completed tasks in place.

Build/run loop (from `CLAUDE.md`):
```bash
xcodegen generate
xcodebuild -project Sandshell.xcodeproj -scheme Sandshell \
  -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
open build/Build/Products/Debug/Sandshell.app   # launch via Finder path → proves PATH fix
```
Never hand-edit `Sandshell.xcodeproj`; edit `project.yml` + `xcodegen generate`.

---

## 1. Locked architecture decisions

- **Window = Workspace = one `sbx` container.** Multiple windows ⇒ multiple roots/containers
  (confirmed with user). Settings/MCP/mount-policy are workspace-scoped per root.
- **Default root** `~/Sandshell` (created if missing); user may pick any folder.
- **Projects are direct subfolders** of the root. Default project **"My Work"**. Adding a
  project creates a subfolder; renaming renames it; sidebar order is stored, not FS-derived.
- **Sessions** are agent terminals run via `sbx exec -w <project-subfolder> <agent>`, hosted
  **in-window**, selected from the sidebar tree, cycled with `⌘⇧[` / `⌘⇧]`, closed with `⌘W`.
- **Mount policy default** (REVISED 2026-06-20 — the original "all non-dot `$HOME` subfolders
  ro" produced 27 mounts on a real machine and **exceeds sbx's ~24-mount ceiling**, see §3):
  a **curated, user-editable** set — root rw; `Downloads`/`Documents`/`Pictures`/`Desktop` ro
  (those that exist); `.agents .claude .codex` rw (the agent config dot-folders); plus
  user-added extras (rw/ro). Resolved set is de-duped and **capped at 24** (root + dot-folders
  prioritized; dropped folders logged, never silent). A **mount-config UI** (shared first-run +
  Settings) edits this. Any mount change ⇒ **stop + rm + recreate** the container.
- **MCP** is configured via `sbx create --static-mcp …` (see §3) — **fixed at creation**, so
  MCP changes ⇒ rebuild. `SBX_MCP_URL` defaults to `https://gateway.docker.com`.
- **Archive** reads **per-agent state files** on the host (config dot-folders are bind-mounted
  rw), never injects prompts. Collectors for claude + codex only (see §9).
- **Git** auto-commits debounced change-bursts with metadata trailers (Project/Session/
  Command/time). Local-only by default; optional remote.
- **Preserved invariants:** not App-Sandboxed; `PathFixer` PATH probe + `setenv`; temp-script
  `sbx exec` launch; `UIDesignRequiresCompatibility` (Sequoia look); deployment target macOS 14.

---

## 2. Open decisions / spikes (resolve as you reach them)

- **SPIKE-1 — RESOLVED 2026-06-20 (ran against live Docker + `sbx`).** **Decision: one
  container per agent kind, N behind one window (Fallback 4).** (Correction: claude and
  claude-bedrock share the same *base image* but are **distinct containers** — they differ in
  credential service + env (`CLAUDE_CODE_USE_BEDROCK`), so they don't collapse onto one running
  container. GA scope is claude + codex anyway. `WorkspaceController` keys containers by
  `AgentKind`.) Evidence:
  - **Images are per-agent and single.** A sandbox = one container = one image. From
    `sandboxlib/agentkits/agents/*/spec.yaml`: `claude` → `docker/sandbox-templates:claude-code-docker`,
    `codex` → `docker/sandbox-templates:codex-docker` (**different** image), and
    `claude-bedrock` → **same** `claude-code-docker` as `claude` (it is the same `claude`
    binary, differing only by env: `CLAUDE_CODE_USE_BEDROCK=1`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
    and a `bedrock` credential source instead of `anthropic`). Probe confirmed: a `claude`
    container has `claude` on PATH but **not** `codex`/`copilot`/`gemini` (Option 1 ✗).
  - **The second binary *can* be runtime-installed but it's not the clean path.** The
    claude image ships node 22 + npm; `npm install -g @openai/codex` inside it succeeded
    (`codex-cli 0.141.0`). So a single container *could* host both, but only by
    bypassing sbx's per-agent provisioning (below) — rejected as the default.
  - **Egress is NOT a differentiator.** All sandboxes get the shared "balanced" preset
    (`sandboxd/pkg/server/policy_defaults.go`): it already allows `**.openai.com`,
    `chatgpt.com`, `api.anthropic.com`, all package managers, GitHub, etc. From a
    claude-only sandbox, `api.openai.com` returned 401 (reachable, just unauthenticated);
    `example.com` was 403 (blocked). So a claude container can already reach OpenAI hosts.
  - **The real differentiator is credential injection / service-auth.** The egress proxy
    (`gateway.docker.internal:3128`) injects credentials and rewrites the auth header only
    for the service(s) declared in the **create-time** agent spec. A claude sandbox's env
    had `SBX_CRED_ANTHROPIC_MODE` but no `SBX_CRED_OPENAI_MODE` — codex inside it would get
    *no* managed OpenAI auth and would have to self-auth from a mounted `~/.codex/auth.json`.
  - **Kits (Option 2) don't help here:** agents are `kind: sandbox`, not composable `mixin`s,
    and no `codex` mixin exists. Option 3 (custom `--template` bundling both) stays a future
    escape hatch for true single-container multi-agent.
  ⇒ `WorkspaceController` keys containers by **`AgentKind`**, lazily `sbx create`s one when a
  session of a new agent kind is first opened in the window. Keep the model able to host N.
- **DEC-A — RESOLVED 2026-06-20:** root rw + other paths ro works fine; the only `sbx`
  restriction on "many paths" is the **24-mount ceiling** (§3). Policy now curated + capped.
- **DEC-B:** commit granularity = debounced burst (recommended) vs literal per-edit.
- **DEC-C — RESOLVED 2026-06-20 (Phase 2):** project delete offers **both** — "Remove from
  Sidebar" (hide; folder stays on disk) and "Move Folder to Trash…" (confirmed; `trashItem`).
- **DEC-D:** `.sandshell/` volatile state git-ignored; only `PROJECT.md` tracked.
- **DEFERRED:** Copilot/Gemini collectors (4a/4b in GA-PLAN); `sbx policy`/`ports`/`secret`/
  `template` UI; "tear session out to its own window".

---

## 3. Verified `sbx` CLI reference (use these exact shapes)

```
sbx create [flags] AGENT PATH [PATH...]      # AGENT ∈ claude|codex|… ; first PATH = rw workspace
   --name <str>            # stable container name (we set this per workspace)
   --static-mcp <list>     # comma list or repeated; FIXED at creation; needs SBX_MCP_URL in env
   --kit <ref>             # repeatable; directory|ZIP|OCI (experimental)
   --template <image>      # custom base image
   --cpus <int> / -m <mem> # resources
   -q                      # quiet
   PATH:ro                 # read-only mount; bare PATH = read-write
sbx ls --json                                # list (current poll source)
sbx exec [-i -t] [-w DIR] [-e K=V] NAME CMD  # run in container; auto-starts if stopped
sbx run --name NAME                          # attach to the agent
sbx stop NAME            sbx rm -f NAME       # lifecycle
sbx kit add …            # attach kit to a running sandbox (experimental)
```

Notes that change the plan:
- **Mount-count ceiling (verified 2026-06-20):** `sbx create` fails with `failed to add nic:
  sailor: ConfigError` (HTTP 500) when given **≥25 bind mounts** (24 OK, 25+ fail; not related
  to rw/ro or specific paths — purely count). The mount policy must stay ≤24 (`MountPolicy.mountLimit`).
- **No `sbx mcp` command exists.** MCP = `--static-mcp` at create, gated on `SBX_MCP_URL`
  being present in the **sbx process environment**. Sandshell must `setenv`/pass
  `SBX_MCP_URL` when invoking `create`. ⇒ resolves open-Q6: **MCP/URL change requires rebuild.**
- `sbx exec` runs *any* command and auto-starts a stopped sandbox — sessions don't need an
  explicit start step.
- Existing `SbxClient.create` already builds positional rw/`:ro` mounts; extend it, don't rewrite.

---

## 4. Target module layout

```
Sandshell/
  App/            AppDelegate, MainMenu                  (extend)
  Sbx/            PathFixer (keep), SbxClient (extend), Models (extend)
                  + Workspace.swift, MountPolicy.swift
                  WorkspaceController.swift  (was SandboxStore — single-container focus)
  Workspace/      WorkspaceState.swift (projects/sessions/order, .sandshell/state.json)
                  ProjectStore.swift, SessionStore.swift  (or merged into WorkspaceState)
  UI/             MainWindowController (extend), SidebarOutlineController (new),
                  SessionHostView / TerminalStackController (new)
                  Settings/SettingsWindowController + *Pane.swift (new)
  Terminal/       SbxCommand (extend: per-session -w, SBX_MCP_URL), TerminalSession (extend)
                  (retire TerminalWindowController/TerminalLauncher separate-window flow)
  Archive/        ArchiveScheduler, SessionStateCollector (protocol),
                  ClaudeCollector, CodexCollector, ProjectDoc
  Git/            GitEngine, FileWatcher
```

---

## 5. Data model & persistence

New/changed models (`Sbx/Models.swift` + new files):
```swift
struct Workspace { var rootURL: URL; var containerName: String;
                   var policy: MountPolicy; var mcpServers: [String];
                   var mcpURL: URL; var primaryAgent: AgentKind }
struct MountPolicy { var extras: [MountSpec]   // user-added beyond the default rule
                     func resolved(home: URL, root: URL) -> [MountSpec] }
struct MountSpec { var path: URL; var readonly: Bool }   // -> "path" or "path:ro"
struct Project { var id: UUID; var folderName: String; var order: Int }
struct Session { var id: UUID; var projectID: UUID; var agent: AgentKind;
                 var name: String; var order: Int; var workdir: String /*container-side*/ }
```

Persistence:
- **Workspace-scoped, volatile** → `<root>/.sandshell/state.json` (projects/sessions/order,
  expansion, watermarks). **git-ignored.**
- **Workspace-scoped, durable** → `<root>/.sandshell/config.json` (policy extras, mcp set,
  mcp URL, primary agent, archive interval). Decide tracked-vs-ignored per DEC-D.
- **App-global** → `UserDefaults` (window frames, terminal font/theme, recent roots).
- **Per-project** → `<root>/<project>/PROJECT.md` (tracked).

---

## 6. Phase 0 — Foundations (model + persistence + bootstrap) — ✅ DONE 2026-06-20

**Objective:** the app can open/create a workspace root, persist its state, and bootstrap the
folder structure — no container or terminal behavior yet.

Tasks:
- [x] Add `Workspace`, `MountPolicy`, `MountSpec`, `Project`, `Session`. Split into
      `Sbx/Workspace.swift` (`MountSpec` + domain `Workspace`), `Sbx/MountPolicy.swift`
      (`MountPolicy.resolved` implements the §1 default rule), `Workspace/WorkspaceState.swift`
      (`Project`/`Session`). Old mount-spec `Workspace` struct → unified into `MountSpec`
      (URL-based; parses `path[:ro]` and renders the `sbx create` arg); `AgentKind` now `Codable`.
- [x] `WorkspaceState` — load/save `<root>/.sandshell/state.json` (atomic, ISO8601 dates);
      creates `.sandshell/` + a `.gitignore` listing `state.json`.
- [x] Root bootstrap (`WorkspaceBootstrap.openOrCreate`): ensures `~/Sandshell`, default project
      `My Work/`, and a seeded `PROJECT.md`. Idempotent — only seeds a project when none exist.
- [x] App-global recent-roots in `UserDefaults` (`RecentRoots`).
- [x] Round-trip verified end-to-end via app relaunch (project UUID preserved, count stays 1).
      NOTE: no XCTest target exists yet; round-trip checked at runtime, not via a unit test.

Files: `Sbx/Workspace.swift`, `Sbx/MountPolicy.swift`, `Sbx/Models.swift`,
`Workspace/WorkspaceState.swift`, `App/AppDelegate.swift`, `UI/DetailView.swift` (MountSpec).

**Done-when:** launching the app creates `~/Sandshell/My Work/PROJECT.md` and a persisted
`.sandshell/state.json`; relaunch restores the same state. ✅ verified (see Progress Log).

---

## 7. Phase 1 — Single-container lifecycle + mount policy + rebuild — ✅ DONE 2026-06-20

**Objective:** opening a workspace creates (or attaches to) one named `sbx` container with the
policy-derived mounts; editing mounts rebuilds it.

Tasks:
- [x] **Run SPIKE-1** (one container, two agents). Verdict: one container **per `AgentKind`**
      behind one window (claude/claude-bedrock share a base image but are distinct containers).
- [x] `MountPolicy` (REVISED): curated `selections` + `includeAgentDotFolders`; `makeDefault`
      seeds `Downloads/Documents/Pictures/Desktop` ro; `resolved(home,root)` → `(mounts, dropped)`,
      root + `.agents/.claude/.codex` rw prioritized, de-duped, **capped at 24** (drops logged).
      Denylists `Library`/`Applications`; skips symlinks, iCloud/ubiquitous, cross-volume (cloud).
- [x] `SbxClient.create(workspace:agent:name:mounts:)` — policy mounts + `--static-mcp` from
      `mcpServers` with `SBX_MCP_URL` injected into the process env only when servers are set.
- [x] `SbxClient.rebuild(...)` = stop → `rm -f` → `create`; `status(name:)` single-container query.
- [x] `WorkspaceController` (@MainActor, new file): owns one `Workspace`, keys containers by
      `AgentKind`, create/attach/rebuild, error surface + `NSLog`. Window owns one; opens primary
      on launch. (`SandboxStore` + flat list UI kept transitionally; retire in Phase 2.)
- [x] Mount signature stored per container in `state.json`; rebuild only on change, behind an
      **NSAlert confirmation** (warns when it kills running sessions).
- [x] **Mount-config UI** (`MountConfigView` + `MountConfigModel`) shown on first workspace open
      (`config.configured==false`), reused by Settings later; folder add/remove, suggested-folder
      toggles, "show agent config folders" toggle (off by default), live `N/24` with cap enforce.
- [x] `WorkspaceConfig` (durable `config.json`): policy, mcp set/URL, primary agent, `configured`.

Files: `Sbx/MountPolicy.swift`, `Sbx/SbxClient.swift`, `Sbx/WorkspaceController.swift` (new),
`Workspace/WorkspaceConfig.swift` (new), `UI/MountConfigView.swift` (new),
`UI/MainWindowController.swift`, `Workspace/WorkspaceState.swift` (mount signatures).

**Done-when:** opening `~/Sandshell` brings up one container named for the workspace with the
expected mounts (verify `sbx ls --json` + `sbx exec <name>` ro/rw); adding a folder triggers a
confirmed rebuild. ✅ verified live (see Progress Log) — incl. first-run UI, attach-on-unchanged,
ro/rw enforcement, and confirmed rebuild.

---

## 8. Phase 2 — Project/Session sidebar tree — ✅ DONE 2026-06-20

**Objective:** sidebar becomes a 2-level tree with reorder, rename, new-session rows, close.

Tasks:
- [x] `SidebarOutlineController` (NSOutlineView, source-list `style = .sourceList`) hosted in the
      split view; SwiftUI flat list retired (`SandboxStore`/`SidebarView`/`DetailView`/
      `CreateSandboxView` deleted). Reloads on `WorkspaceController.objectWillChange`; stable
      node identity (`ProjectNode`/`SessionNode`/`NewSessionNode`) preserves expansion.
- [x] Render Projects (expandable) → Sessions + trailing **"＋ New Session"** row.
- [x] Project ops: add (`New Project` footer button → creates subfolder + `PROJECT.md`, inline
      rename), rename (folder move + state + re-points session workdirs; no-op guard), reorder
      (drag-drop at root), delete per DEC-C ("Remove from Sidebar" hide / "Move Folder to Trash…").
- [x] Session ops: add (`＋ New Session` → primary agent; right-click submenu for claude/codex),
      reorder within project (drag-drop), close (hover **X** + Delete key + `⌘W` via
      `closeCurrentSessionOrWindow`), select.
- [x] Selection publishes to `WorkspaceController.selection` (drives Phase 3 terminal host);
      detail pane is a SwiftUI `WorkspaceDetailView` placeholder until Phase 3.
- [x] Context menus (right-click) mirroring ops (New Session submenu, Rename, Close, Remove, Trash).

Files: `UI/SidebarOutlineController.swift` (new), `UI/WorkspaceDetailView.swift` (new),
`Sbx/WorkspaceController.swift` (project/session ops + `SidebarSelection`),
`Workspace/WorkspaceState.swift`, `UI/MainWindowController.swift`, `App/MainMenu.swift` (@MainActor).

**Done-when:** can create/rename/reorder projects and sessions; layout persists across relaunch;
"＋ New Session" creates a session row bound to the project's workdir. ✅ verified (see Progress
Log) — create/rename/persistence/workdir/tree live-verified; reorder implemented (drag-drop).

---

## 9. Phase 3 — In-window terminal sessions — ✅ DONE 2026-06-20

**Objective:** the detail pane shows the selected session's live terminal; sessions persist in
the background; `⌘⇧[`/`⌘⇧]` cycle; naming follows typed input.

Tasks:
- [x] `TerminalStackController`: one `TerminalSession` per live session; its view is added to a
      stable host **once** and shown/hidden via `isHidden` + `setSurfaceVisible` — never
      re-parented. Placeholder when none; prunes terminals when sessions close.
- [x] Reworked `TerminalSession` (one libghostty controller/surface, `.exec`, temp-script
      command) to launch from a session spec; per-session `-w <container workdir>` in `SbxCommand`.
- [x] `SbxCommand` injects `SBX_MCP_URL` into the session env (only when the workspace has MCP).
- [x] Launch = `sbx exec -it -w <workdir> <container> env … bash -c '… exec <agent>'`, with the
      agent's container brought up lazily (`ensureContainerReady`) — claude/codex per session.
- [x] Session naming (revised per user 2026-06-20): new sessions are named **"New Claude
      Session"/"New Codex Session"** and an existing **pristine** session (same project+agent,
      never manually renamed → `Session.autoNamed`) is **reused** instead of creating duplicates.
      Terminal-title auto-naming was removed (it collapsed all claude sessions to one title).
      Richer claude `aiTitle`/`lastPrompt` naming deferred to the archive phase (§10/§13).
- [x] Selection → visible surface; `⌘W` closes the selected session (terminate exec, drop view,
      update state) via `AppDelegate.closeSessionOrWindow`; `⌘⇧[`/`⌘⇧]` cycle via `selectAdjacentSession`.

Files: `UI/TerminalStackController.swift` (new), `Terminal/SbxCommand.swift`,
`Terminal/TerminalSession.swift`, `UI/MainWindowController.swift`, `App/MainMenu.swift`,
`App/AppDelegate.swift`. Retired `Terminal/TerminalLauncher.swift` + `TerminalWindowController.swift`.

**Done-when:** selecting sessions swaps terminals without blanking; both a claude and a codex
session run concurrently in one window (gated on SPIKE-1); names update from input; `⌘W` closes.
✅ verified live — claude (`sandshell`) + codex (`sandshell-codex`) ran concurrently with their
agent processes; session auto-named to "Claude Code" from the title; build clean.

---

## 10. Phase 4 — Settings window (`⌘,`) — ✅ DONE 2026-06-20

**Objective:** standard macOS settings window with a row of colored icon "tabs".

Tasks:
- [x] `SettingsWindowController`: `NSWindow` + `NSToolbar` (`.preference` style, selectable items,
      System-Settings-style tinted rounded SF-Symbol icons), swapping hosted pane VCs and
      resizing to each pane's fitting size.
- [x] **General** pane (SwiftUI `Form`): root folder (+ Reveal in Finder), primary-agent picker,
      archive-interval stepper. (Polling dropped — the workspace model no longer polls a list.)
- [x] **Mounts** pane reuses `MountConfigView` ("Apply & Rebuild") showing the current policy;
      Apply persists config and rebuilds every existing container (the rebuild confirmation is
      the "rebuild required" affordance).
- [x] Stub panes for **MCP**, **Git/Remote**, **Appearance** (filled in later phases).
- [x] Menu: **Settings… (`⌘,`)** in the app menu → `AppDelegate.openSettings` →
      `MainWindowController.showSettings` (lazy, retained).
- [x] Durable config persists to `<root>/.sandshell/config.json` (`setPrimaryAgent`,
      `setArchiveInterval`, `applyConfiguration`); `archiveInterval` added to `WorkspaceConfig`.

Files: `UI/Settings/SettingsWindowController.swift`, `UI/Settings/SettingsPanes.swift`,
`Sbx/WorkspaceController.swift`, `Workspace/WorkspaceConfig.swift`, `App/MainMenu.swift`,
`App/AppDelegate.swift`, `UI/MainWindowController.swift`.

**Done-when:** `⌘,` opens a paned settings window; changing mounts shows a "rebuild required"
affordance and rebuilds on apply. ✅ verified — Settings opens with 5 tinted tabs; switching tabs
swaps panes (window title follows); the Mounts pane renders the live policy + "Apply & Rebuild".

---

## 11. Phase 5 — MCP management UI

**Objective:** choose which MCP servers the container exposes (`--static-mcp`), with editable
`SBX_MCP_URL`.

Tasks:
- [ ] **MCP** settings pane: editable `SBX_MCP_URL` (default `https://gateway.docker.com`);
      list of selected servers (multi-select; comma-join into `--static-mcp`).
- [ ] Discover available servers (best-effort): query the gateway if it exposes a list,
      else free-text entry. *(Investigate gateway listing; free-text fallback is acceptable.)*
- [ ] `SbxClient.create`: pass `--static-mcp` and ensure `SBX_MCP_URL` is in the process env.
- [ ] Changing MCP set or URL marks pending **rebuild** (it's fixed at creation).

Files: `UI/Settings/McpPane.swift`, `Sbx/SbxClient.swift`, `Sbx/Workspace.swift`.

**Done-when:** selecting servers + applying rebuilds the container with `--static-mcp`; the
agent sees the chosen MCP servers.

---

## 12. Phase 6 — Git engine

**Objective:** the workspace is a git repo; file-change bursts become attributed commits;
optional remote.

Tasks:
- [ ] `GitEngine` (shell `git` via `Process`, mirroring `SbxClient`): `init` if absent; seed
      `.gitignore` (ignore `.sandshell/state.json` + caches; track `PROJECT.md`); `commit`.
- [ ] `FileWatcher` (FSEvents on root; debounce bursts ~1–2s).
- [ ] On burst: commit with trailers
      `Sandshell-Project: …` / `Sandshell-Session: …` / `Sandshell-Command: …`.
- [ ] Attribution: map a burst to the active session + its last command (from Phase 3 input
      capture). Decide DEC-B (debounce vs literal) — default debounce.
- [ ] Settings → **Git/Remote** pane: show repo status; add/link `origin`; push toggle.

Files: `Git/GitEngine.swift`, `Git/FileWatcher.swift`, `UI/Settings/GitPane.swift`.

**Done-when:** edits inside a session produce commits whose trailers name the project/session/
command; `git log --grep=Sandshell-Session` filters history; remote link works when configured.

---

## 13. Phase 7 — Auto-archive + `PROJECT.md`

**Objective:** every N minutes (default 5, configurable) merge each session's new activity into
its project's `PROJECT.md`, from **per-agent state files** (no prompt injection). New sessions
init from `PROJECT.md`.

Tasks:
- [ ] `SessionStateCollector` protocol (input: agent kind + container-side workdir + watermark;
      output: new turns/summary since watermark).
- [ ] `ClaudeCollector`: read `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` where encoded-cwd
      = **container-side** workdir with `/`→`-`; pull user prompts + assistant turns since
      watermark; reuse `aiTitle`/`lastPrompt`.
- [ ] `CodexCollector`: read `~/.codex/sessions/YYYY/MM/DD/*.jsonl` (+ `history.jsonl`); select
      rollout whose `cwd` matches the session workdir; pull new turns.
- [ ] `ArchiveScheduler`: timer (configurable), per-session watermark, throttle.
- [ ] `ProjectDoc`: read/merge/write `<root>/<project>/PROJECT.md`; commit via `GitEngine`.
- [ ] New-session init: read `PROJECT.md` and seed the agent (initial context/prompt).

Files: `Archive/SessionStateCollector.swift`, `Archive/ClaudeCollector.swift`,
`Archive/CodexCollector.swift`, `Archive/ArchiveScheduler.swift`, `Archive/ProjectDoc.swift`.

**Done-when:** after activity, `PROJECT.md` reflects each session's work; re-running is
idempotent (watermark); a new session opens primed with the project's prior context.

---

## 13b. Theming & appearance (design handoff `design_handoff_sandshell_gui/`)

**Objective:** implement the high-fidelity visual design + a flexible theming system.
Design spec: `design_handoff_sandshell_gui/README.md` (light/dark base palettes, sidebar +
detail chrome, agent badges, status indicators, framed terminal). User-expanded requirements
beyond the handoff's 3 fixed themes:
- **Appearance mode**: Light / Dark / **Follow System**, with **separate light & dark settings**.
- **Chrome**: configurable **key color** + **accent** color(s) (default Docker Ocean `#1d63ed`).
- **Terminal theme**: built-in presets **and** custom colors (ghostty `bg/fg/dim/accent/green/red`).
- **Per-session color/tag**: each session can be colored/tagged (beyond the agent color).

Breakdown:
- [x] **Foundation**: `ThemeColors` token set (light/dark bases from the handoff), `AppearanceMode`,
      `ThemePreferences` (Codable, per-mode key+accent), `ThemeController` (resolves effective
      appearance, applies `NSAppearance`, observes the system, persists, publishes). Appearance
      settings pane: mode control + key/accent color wells per light/dark.
- [x] **Chrome redesign** (per handoff): merged title bar; sidebar header (app mark in key color,
      workspace identity, gear), "Search sessions" field, session rows with colored **agent badges**
      + subline, "New Project" footer; detail **session header bar** (badge, name, container·workdir,
      status) + **framed terminal** (rounded border, title strip, termBg). Observes ThemeController.
      (Search is wired but not yet filtering; uses native source-list material for the sidebar bg.)
- [x] **Terminal theme**: `TerminalPalette` + built-in presets (Sandshell / Alabaster·Afterglow /
      Solarized / Tokyo Night, full 16-color ANSI) + custom editor; pushed to ghostty as a live
      `TerminalTheme` (`setTheme`/`setColorScheme`) so palette + light↔dark re-color open terminals.
      (Font is still hardcoded SF Mono 13 / block cursor — see Phase 8.)
- [x] **Appearance system** (added): two resolved palettes — main (detail/window/terminal) +
      independently-themed sidebar ("Sidebar always dark"); user-settable Key/Accent/Sidebar/
      Background per light & dark; explicit chrome painting (sidebar forces its own NSAppearance,
      window bg + header continuous with Background). Fixed @Published willSet lag that rendered
      the chrome one scheme behind.
- [ ] **Session color/tag**: per-session color in `Session`; colored badge in sidebar; picker.
- [x] **Status model + work-time**: `working`/`ready` (precise end-of-turn from transcript
      `stop_reason`) + live work-time + unread amber dot; sidebar rows (animated whale while
      working) + detail header.

Files: `Theme/*` (new), `UI/Settings/SettingsPanes.swift` (Appearance), `UI/SidebarOutlineController.swift`,
`UI/TerminalStackController.swift`, `Terminal/TerminalSession.swift`, `Sbx/Models.swift` (AgentKind glyph/color),
`Workspace/WorkspaceState.swift` (Session color).

---

## 14. Phase 8 — Polish

Tasks:
- [ ] Keybindings: `⌘⇧[`/`⌘⇧]` session tab nav; `⌘⌥↑`/`⌘⌥↓` sidebar move; `⌘W` close session;
      `⌘,` settings; New Project / New Session / New Window menu items.
- [ ] **Appearance** pane: terminal font/theme (replace hardcoded SF Mono 13 / block cursor).
- [ ] Remote polish: status indicator, push-on-commit toggle.
- [ ] History view: browse commits by Project/Session/Command/time.
- [ ] "New Window" → root chooser (default `~/Sandshell`).

Files: `App/MainMenu.swift`, `UI/Settings/AppearancePane.swift`, `UI/MainWindowController.swift`,
optional `UI/HistoryView.swift`.

**Done-when:** all keybindings work; appearance persists; multiple workspace windows coexist.

---

## 15. Cross-cutting invariants (do not break)

- App is **not** App-Sandboxed (`ENABLE_APP_SANDBOX: NO`); libghostty spawns `sbx exec`.
- `PathFixer` runs before any `sbx` call; `sbx`/`docker`/`brew` resolve via patched PATH.
- Terminal launch always via temp `+x` script + libghostty `command =` config, backend `.exec`.
- `UIDesignRequiresCompatibility = true` (Sequoia look); deployment target macOS 14.
- All `sbx` calls go through `SbxClient` (actor); UI state through `@MainActor` controllers.
- Regenerate the Xcode project with `xcodegen generate` after adding files; never edit the
  `.xcodeproj` by hand.

---

## 16. Risk register

- **SPIKE-1 RESOLVED** → one container per (image, credential-service); claude + claude-bedrock
  share one. `WorkspaceController` manages N containers behind one window, created lazily per
  agent kind. (Was: "unresolved, may force one-container-per-agent" — confirmed it does.)
- **In-window terminal blanking** (known prior failure) → strict no-re-parent hosting; verify
  early in Phase 3 with a throwaway 2-surface test.
- **Mount count** → enumerating all `$HOME` subdirs as `:ro` could be many mounts / slow start;
  measure; consider a cap or opt-in list if Docker struggles.
- **Archive path mapping** → encoded-cwd uses the **container-side** workdir, not host path; a
  mismatch yields empty archives. Assert the mapping in a test.
- **Auto-commit noise** → debounce + attribute; avoid committing `.sandshell/state.json`.
- **MCP discovery** → gateway may not list servers; free-text fallback acceptable for GA.

---

## 17. Progress Log (append at the end of each session)

> Format: `### YYYY-MM-DD — <summary>` then bullets: landed / decisions / next.

### 2026-06-20 — Plan authored
- Mapped Milestone 1 code; verified `sbx` CLI (no `sbx mcp`; MCP = `--static-mcp` at create,
  gated on `SBX_MCP_URL`; create is per-AGENT). Scoped GA to claude + codex.
- Verified archive state files exist for claude (`~/.claude/projects/<encoded-cwd>/*.jsonl`,
  with `aiTitle`/`lastPrompt`) and codex (`~/.codex/sessions/Y/M/D/*.jsonl`).
- Decisions locked in §1; open items in §2 (notably **SPIKE-1**).
- **Next:** Phase 0 tasks (models + `WorkspaceState` + root bootstrap), then **SPIKE-1**
  before committing Phase 1's container model.

### 2026-06-20 — SPIKE-1 run (live Docker + `sbx`)
- **Result: one container per (image, credential-service); claude + claude-bedrock collapse to
  one.** Full evidence in §2 (SPIKE-1 RESOLVED). Method: created a throwaway `claude` sandbox
  over a temp workspace and probed it; cross-checked against `../sandboxes` source.
- Key facts pinned from source (`sandboxlib/agentkits/agents/*/spec.yaml`): claude image
  `claude-code-docker`, codex image `codex-docker` (different), claude-bedrock = same image as
  claude (env-only delta). Egress is a shared "balanced" preset
  (`sandboxd/pkg/server/policy_defaults.go`), not per-agent — already allows OpenAI + Anthropic
  + package managers, so it's not a blocker. Per-agent delta that matters = credential
  injection/service-auth (proxy at `gateway.docker.internal:3128`, keyed on create-time agent).
- Empirically: `claude` container has only `claude` on PATH (no codex); `npm install -g
  @openai/codex` inside it works (image has node 22), but that bypasses sbx cred provisioning →
  not the default path. Test sandbox removed; no residue.
- **Next:** start Phase 0 — `Workspace`/`MountPolicy`/`Project`/`Session` models +
  `WorkspaceState` persistence + root bootstrap. Design `WorkspaceController` to key containers
  by **(image, credential-service)** and create them lazily per agent kind.

### 2026-06-20 — Phase 0 complete (foundations)
- Landed models: `MountSpec` (URL-based; unifies the old `sbx ls` mount-spec parser + the
  `sbx create` arg renderer), domain `Workspace`, `MountPolicy` (with `resolved(home:root:)`
  implementing the §1 default rule: root rw, non-dot `$HOME` subfolders ro, dot-folders excluded
  except `.agents`/`.claude`/`.codex` rw, then user extras), `Project`, `Session`. `AgentKind`
  is now `Codable`.
- `WorkspaceState` persists projects/sessions/expansion/watermarks to
  `<root>/.sandshell/state.json` (atomic, ISO8601). `WorkspaceBootstrap.openOrCreate` ensures the
  root, `.sandshell/` + `.gitignore` (ignoring `state.json`), default `My Work/` project, and a
  seeded `PROJECT.md`. `RecentRoots` tracks roots in `UserDefaults`. Bootstrap runs at launch in
  `AppDelegate` (UI integration deferred to Phase 2).
- **Verified:** `xcodegen generate` + Debug build succeed; launching the built app creates
  `~/Sandshell/{My Work/PROJECT.md, .sandshell/{state.json,.gitignore}}`; relaunch preserves the
  project UUID (count stays 1). No XCTest target yet — round-trip checked via relaunch.
- **Next:** Phase 1 — single-container lifecycle. Build `WorkspaceController` keyed by
  (image, credential-service) per the SPIKE-1 verdict; wire `MountPolicy.resolved` into the
  `sbx create` mount args (replacing the hardcoded list in `SbxClient.create`); mount-change ⇒
  stop + rm + recreate.

### 2026-06-20 — Phase 1 complete (single-container lifecycle + mount policy + rebuild)
- **Key finding — sbx 24-mount ceiling:** `sbx create` fails with `failed to add nic: sailor:
  ConfigError` at **≥25 bind mounts** (bisected: 24 OK, 25 FAIL; independent of rw/ro or path).
  Recorded in §3. This forced redesigning the mount policy.
- **Mount policy redesigned** (was "all non-dot `$HOME` subfolders ro" → 27 mounts on this
  machine, over the ceiling). Now **curated + capped at 24**: root rw + `Downloads/Documents/
  Pictures/Desktop` ro + `.agents/.claude/.codex` rw, plus user-added folders. Denylists
  `Library`/`Applications`; skips symlinks (e.g. Google Drive), iCloud/ubiquitous, and
  cross-volume cloud/FUSE mounts. `resolved()` returns `(mounts, dropped)`; drops are logged.
- **Mount-config UI** (`MountConfigView`/`MountConfigModel`): shown as a sheet on first workspace
  open (driven by `WorkspaceConfig.configured`), reused by Settings later. Suggested-folder
  toggles, add/remove other folders, "show agent config folders" toggle (off by default), live
  `N/24` counter with cap enforcement.
- **Lifecycle:** `WorkspaceController` (@MainActor) keys containers by `AgentKind`,
  create/attach/rebuild with per-container mount signatures in `state.json`; rebuild gated behind
  an NSAlert confirmation. `SbxClient` gained `create(workspace:…)`, `rebuild(…)`, `status(name:)`
  and a per-call env override (`SBX_MCP_URL` only when `--static-mcp` used). `WorkspaceConfig`
  (`config.json`, durable) persists policy/mcp/primaryAgent/configured.
- **Verified live (Docker + AppleScript-driven UI):** first-run shows the sheet & does not
  auto-create; confirming creates `sandshell` (root rw, dot-folders rw, picked folders ro — ro/rw
  enforced via `sbx exec` write tests); relaunch **attaches** (no duplicate, no sheet); editing
  the policy triggers the **confirmed rebuild** (NSAlert → Rebuild → container recreated with the
  new mount). Build clean (no warnings/errors). Test container removed; user's sandboxes untouched.
- **Correction:** SPIKE-1 note fixed — claude + claude-bedrock share a *base image* but are
  distinct containers (different cred service + env), so containers are keyed by `AgentKind`.
- **Carry-over for Phase 2:** `SandboxStore` + the flat-list `SidebarView`/`DetailView` remain
  transitionally (window still shows the old list); retire them when the project/session tree
  lands. The `WorkspaceController` is the authority going forward.
- **Next:** Phase 2 — Project/Session sidebar tree (`SidebarOutlineController`), binding selection
  to `WorkspaceController`; retire `SandboxStore`.

### 2026-06-20 — Phase 2 complete (project/session sidebar tree)
- **Retired the Milestone-1 list UI**: deleted `SandboxStore`, `SidebarView`, `DetailView`,
  `CreateSandboxView`. The window now opens a `WorkspaceController` first, hosts a
  `SidebarOutlineController` (NSOutlineView source list) + a SwiftUI `WorkspaceDetailView`
  placeholder. Terminal infra (`Terminal/*`) untouched (Phase 3).
- **WorkspaceController** gained project/session CRUD + `SidebarSelection` (project/session):
  add/rename/reorder/hide/trash project, add/rename/reorder/close session. Session `workdir` =
  the project subfolder's host path (mounts land at host path). All mutations persist `state.json`
  and publish `objectWillChange` (mutate-then-send) → the outline reloads, preserving expansion
  (stable node identity) and selection.
- **Sidebar**: projects expandable → sessions + trailing "＋ New Session" row; inline rename
  (editable cell text fields), hover **X** close on session rows, Delete-key + `⌘W` close,
  drag-drop reorder (projects at root / sessions within a project), right-click context menus
  (New Session submenu picks claude/codex), "New Project" footer button. Agent icon per session.
- **DEC-C resolved**: project delete offers "Remove from Sidebar" (hide; folder kept) and
  "Move Folder to Trash…" (confirmed `trashItem`).
- **Verified live** (Docker + interactive use): created multiple projects (folders + `PROJECT.md`,
  unique-naming) and sessions (correct primary agent, **workdir bound to the project subfolder**),
  renamed a session (persisted), relaunched with all state intact (3 projects, 7 sessions, 3
  expanded) and the tree rendering correctly (13 rows = 3 projects + 7 sessions + 3 new-session
  rows). Reorder is implemented via drag-drop (not independently scripted — AX gestures fragile).
  Caught & fixed a no-op-rename bug (end-editing fired unchanged would uniquify the name to "… 2").
- **Build**: clean, zero warnings (also made `MainMenu.install` `@MainActor`, dropped the
  deprecated `selectionHighlightStyle`).
- **Note**: my live testing + the user's interaction left sample projects/sessions in
  `~/Sandshell` (`My Work`, `New Project 2/3`, several `claude` sessions, one renamed `sdfdsf`);
  these are real workspace data and can be removed via the sidebar (Remove / Trash / Close).
- **Next:** Phase 3 — in-window terminal sessions: `TerminalStackController`/`SessionHostView`
  (show active, hide others — never re-parent), per-session `sbx exec -it -w <workdir> <name> …`,
  `⌘⇧[`/`⌘⇧]` cycling. Selection already flows from the sidebar to `WorkspaceController.selection`.

### 2026-06-20 — Phase 2 sidebar fixes (post-review feedback)
- **First click now selects.** Cell name fields were `isEditable`/`isSelectable`, so the first
  click was swallowed by the field instead of selecting the row. They're now display labels
  (non-editable/non-selectable); `beginRename` flips a field editable on demand and resets it on
  commit.
- **Rename no longer dies on the first try.** The sidebar sank the catch-all `objectWillChange`,
  so a selection change (fired when right-clicking/selecting before Rename) triggered a full
  `reloadData()` that tore down the just-opened editor. Added `WorkspaceController.revision`
  (bumped only on structural project/session changes) and the sidebar now reloads on `$revision`
  — selection/busy/error changes no longer reload the tree. Expansion persistence (`setProject`)
  saves quietly without bumping `revision`.
- **Keybinding:** session cycling is `⌘⇧[`/`⌘⇧]` (not `⌘[`/`⌘]`) — updated throughout the plan;
  applies when Phase 3 wires it up.

### 2026-06-20 — Phase 3 complete (in-window terminal sessions)
- **Terminal hosting**: `TerminalStackController` keeps one `TerminalSession` per live session;
  views are added to a stable host once and toggled `isHidden`/`setSurfaceVisible` — never
  re-parented (the prior blanking failure). Selecting a session brings its agent's container up
  lazily (`ensureContainerReady`), then creates + shows the terminal; others persist hidden.
- **Launch**: reworked `TerminalSession`/`SbxCommand` to take a session spec (container, workdir,
  agent, mcpURL) and run `sbx exec -it -w <workdir> <container> env … bash -c 'exec <agent>'`,
  injecting `SBX_MCP_URL` only when the workspace has MCP servers. Retired the old separate-window
  flow (`TerminalLauncher`/`TerminalWindowController`).
- **Auto-naming**: libghostty `TerminalSurfaceTitleDelegate` → `applyTerminalTitle`, guarded by
  `Session.autoNamed` (manual rename pins the name). Verified: a session auto-named to "Claude
  Code" from the agent's terminal title.
- **Keys**: `⌘⇧[`/`⌘⇧]` cycle sessions (`selectAdjacentSession`), `⌘W` closes the selected session
  (else the window) — wired through `AppDelegate` + the menu. Programmatic selection now syncs the
  sidebar highlight (guarded against feedback loops).
- **Verified live**: selecting a claude session created/launched `sandshell` with a live `claude`
  process; adding a codex session created `sandshell-codex` with a live `codex` process — both
  containers + agents running concurrently in one window (SPIKE-1 model holds).
- **Fixes from review feedback**:
  - *Top of shell cut off*: the Metal-backed terminal drew under the title bar with
    `.fullSizeContentView`; pinned the terminal host to the safe-area layout guide (sidebar already
    insets itself). Verified the first line is now fully visible.
  - *Projects start expanded*: new + default projects are seeded into `expandedProjectIDs` so the
    "New Session" row is visible immediately.
  - *Workspace root rw*: confirmed `~/Sandshell` is always the first (rw) mount and project
    subfolders (e.g. `My Work`) are writable under it — no change needed.
- **Note**: a codex test session was injected into `~/Sandshell` state for the concurrent test;
  it's a normal session and can be closed from the sidebar.
- **Next:** Phase 4 — Settings window (`⌘,`): reuse `MountConfigView` as the Mounts pane.

### 2026-06-20 — Phase 4 complete (Settings window)
- `SettingsWindowController` (AppKit `NSToolbar`, `.preference` style) with 5 selectable tabs —
  General, Mounts, MCP, Git, Appearance — each a tinted rounded SF-Symbol icon (System-Settings
  look), swapping hosted SwiftUI panes and resizing to fit.
- **General** pane (SwiftUI `Form`): root folder + Reveal in Finder, primary-agent picker
  (`setPrimaryAgent`), archive-interval stepper (`setArchiveInterval`). **Mounts** pane reuses
  `MountConfigView` ("Apply & Rebuild") → `applyConfiguration` (persists + rebuilds all existing
  containers). MCP/Git/Appearance are stub panes for later phases.
- Wiring: `Settings… (⌘,)` in the app menu → `AppDelegate.openSettings` →
  `MainWindowController.showSettings` (lazily creates + retains the controller).
  `WorkspaceConfig` gained `archiveInterval`; `applyConfiguration` now rebuilds every existing
  agent container (not just the primary) on a mount change.
- **Verified live**: ⌘,/menu opens the paned window; clicking a toolbar tab swaps the pane and
  updates the title; the Mounts pane shows the live policy (root rw, suggested ro, the user's
  extra folders, "11 / 24 mounts") with the Apply & Rebuild action. Build clean (zero warnings).
- **Refinement noted**: the "rebuild required" cue is the labeled "Apply & Rebuild" button +
  rebuild-confirmation alert, rather than a separate banner that appears on edit.
- **Next:** Phase 5 — MCP management UI (fill the MCP pane: editable `SBX_MCP_URL`, server
  multi-select → `--static-mcp`, rebuild on change).

### 2026-06-20 — Phase 4 UI refinements (feedback)
- **Settings window no longer jumps** when switching tabs: panes of different heights were
  re-anchoring to the bottom-left. `select()` now captures the top edge *before* swapping
  `contentViewController` (which auto-resizes), then re-sets the frame anchored to the original
  top-left. Verified: top-left constant across General↔Mounts.
- **Toolbar tab spacing**: flexible spaces at both ends + a fixed `.space` between each tab.
- **(i) info button** in `MountConfigView` next to the confirm action, with a popover describing
  what it does (`confirmInfo` param) — "Apply & Rebuild" explains the rebuild/lost-sessions
  behavior; the first-run "Create Workspace" variant explains container creation.

### 2026-06-20 — Mounts editor UX + agent HOME fix (feedback)
- **Settings ▸ Mounts** is now change-aware: `MountConfigModel` tracks a `baseline`; **Apply &
  Rebuild** and **Revert** are enabled only when there are unsaved changes; changed rows show an
  orange dot and the footer shows "• Unsaved changes". Leaving the pane (tab switch or window
  close) with unsaved edits forces an **Apply & Rebuild / Revert / Cancel** modal
  (`resolveUnsavedMounts`). First-run keeps an always-enabled "Create Workspace" + "Cancel".
- `WorkspaceController` gained a `MismatchAction` (prompt/attach/rebuild); Settings-Apply rebuilds
  via `rebuildContainer` (no second confirmation — the editor already confirmed).
- Settings window no longer animates the resize on tab switch (`animate: false`), and the resize
  is anchored top-left so it doesn't jump.
- **Agent HOME fix**: `SbxCommand` no longer overrides `HOME` to the macOS host home — that made
  claude look for its install at `<hosthome>/.local/bin` and warn "native installation … missing
  or broken". `HOME` now stays the container's `/home/agent` (where claude/codex are installed);
  `CLAUDE_CONFIG_DIR`/`CODEX_HOME` still point at the mounted host config dirs so credentials,
  settings, and transcripts use the user's real `~/.claude` / `~/.codex`. Verified: in-container
  `~/.local/bin` is present + on PATH and `claude --version` runs.

### 2026-06-20 — Build progress + Apply confirmation (feedback)
- **Build/rebuild notification**: `WorkspaceController.activity` (e.g. "Building sandshell…",
  "Rebuilding sandshell…") is set around `sbx create`/`rebuild` and cleared when done.
  `TerminalStackController` now drives the detail pane from a single `refresh()` and shows a
  centered **spinner + status** whenever `isBuilding` (replacing a fragile NSVisualEffectView
  banner that didn't render). A rebuild drops stale terminals (their containers were recreated)
  so re-selecting relaunches.
- **No new sessions mid-build**: the sidebar's "＋ New Session" button + the context-menu agent
  submenu are disabled while `isBuilding`; the sidebar re-renders on `$activity`. Concurrent
  `sbx create`s are avoided — a session selected during a build launches once the build finishes.
- **Apply & Rebuild** in Settings ▸ Mounts now opens a **confirmation modal**; on accept it
  applies, commits the baseline, and **closes the Settings window** (clean close — no longer
  dirty). Leaving the pane with unsaved changes still shows the Apply/Revert/Cancel force-choice.

### 2026-06-21 — Sidebar/terminal/window fixes + transcript auto-naming (feedback)
- **⌘, (and ⌘W / ⌘⇧[ ]) eaten by the terminal**: Ghostty consumes any key matching its keybinds
  (cmd+comma = open config, etc.). Unbound the shortcuts our menu owns in the terminal config
  (`super+comma`, `super+w`, `super+shift+left_bracket`/`right_bracket`) so they reach the menu.
- **Rename wasn't committing**: cell name fields were `NSTextField(labelWithString:)` (a label);
  rebuilt as normal borderless fields so toggling `isEditable` during rename gives a working
  field editor that commits via `controlTextDidEndEditing`.
- **Re-clicking a not-yet-started session didn't launch it**: re-clicking an already-selected row
  doesn't fire `selectionDidChange`, so added a single-click action that re-publishes the
  selection → `refresh()` re-launches.
- **⌘W now closes the key auxiliary window** (Settings) before the main window; added **Window ▸
  Sandshell (⌘0)** + robust dock-reopen so the main window can always be brought back.
- **Session auto-naming from the first prompt** (`TranscriptReader`): libghostty's `.exec` backend
  exposes no viewport/typed-text read, so we read the agent's transcript — claude writes to the
  mounted `~/.claude/projects/<encoded-cwd>/*.jsonl` (cwd → non-alphanumerics replaced by `-`).
  After a session launches, a poll watches for the first user prompt and names the session
  (e.g. "me talk pretty?"), marking it used (`autoNamed=false`) so it's no longer reused and the
  next "New Session" makes a fresh one. Codex transcript layout deferred. (This is the focused
  slice of the §13 aiTitle/lastPrompt naming.)

### 2026-06-21 — Session naming model finalized + one-click New Session (feedback)
- **Sessions are auto-named only** — manual session rename removed (`renameSession`, session
  Rename context item, editable session cell all gone); **projects remain renameable**. Dropped
  the `manuallyNamed`/`autoNamed` flag entirely.
- **Name tracks the latest prompt continuously**: `TranscriptReader.latestPrompt` returns the most
  recent user message; the watcher polls ~1.5s while the terminal is alive and updates the name
  (no-ops when unchanged). Reuse = a session still showing its default "New … Session" name.
- **One-click New Session**: the whole "New Session" row is handled in `SidebarOutlineView.mouseDown`
  (`onNewSessionRow`) instead of an embedded button (which needed two clicks in a non-selectable
  table row); it creates/selects the session and starts its terminal immediately. The row dims
  while a container is building.
