# Sandshell release UI tests

AppleScript smoke/regression tests for cutting a Sandshell release, run via
`osascript` and orchestrated by `scripts/run-ui-tests.sh`.

## Run them

```bash
scripts/run-ui-tests.sh                 # build Debug + run the full suite
scripts/run-ui-tests.sh --skip-build    # reuse the last Debug build
scripts/run-ui-tests.sh --app path/to/Sandshell.app
scripts/run-ui-tests.sh --force-quit    # quit a running Sandshell first
scripts/run-ui-tests.sh --keep-open     # leave the test instance open afterward
```

Must run on macOS (osascript, sbx, and the built app all only exist there).
From a Claude Code sandbox with the `hatch-kit` bridge configured, invoke it
via hatch's `launch` tool targeting `/bin/bash -c 'cd $WORKSPACE_DIR &&
scripts/run-ui-tests.sh > .hatch/ui-tests.log 2>&1'`, then `wait_for_exit` and
read the log back — same pattern as running `xcodebuild` from the sandbox
(see `hatch-kit.md`).

## Why it's built this way

**Sandshell isn't a scriptable application** (no `.sdef`) — it's an AppKit app
with an Accessibility tree like any other. Two things make it testable
without fighting that:

1. **A minimal built-in test bridge** (DEBUG, `UITestHeadless` in
   `App/SelfTest.swift`): the runner passes `-SandshellUITestBridge <dir>`
   and the tests write a command to `<dir>/request` — `stat` returns JSON
   describing every window (sidebar order, build state, empty-state text) and
   session (agent, workdir, running/live state, unread flag, work time);
   `news` does the equivalent of ⌘N; `open <url>` handles a `sandshell://`
   URL — and read the JSON back from `<dir>/response`. It's files rather than
   the app's `'Shll'` Apple Events (still there for `scripts/sandshell`)
   because each fresh ad-hoc-signed test build would need its own Automation
   approval — a dialog. This lets the suite verify the real `sbx create` →
   container → terminal pipeline by polling state instead of reading pixels.
2. **A handful of `.accessibilityIdentifier(...)` tags** added to
   `SandboxesPane.swift` and `InspectorView.swift` so the Settings ▸ Sandboxes
   lifecycle test (Stop/Run/Delete) can address specific rows/buttons
   reliably instead of matching on button titles that repeat across rows.

Everything else (menu structure) is read directly off the accessibility tree
by title, since menu titles are already stable, real UI.

## Safety model — read this before changing the suite

The suite runs **beside** your own Sandshell, without taking focus:

- The runner builds the Debug app with its own bundle id
  (`com.xmas.sandshell.uitest`), so the test instance has separate
  UserDefaults (no restored windows or layouts) and System
  Events address it by that id — never your `com.xmas.sandshell`. It refuses
  an app carrying the release bundle id.
- It runs a copy (`build-uitests/SandshellUITest.app`) whose executable is
  renamed `SandshellUITest` and re-signed ad hoc: System Events re-resolves
  process references by executable name, so with two "Sandshell" processes
  AX actions could land in yours. `appProcess` refuses any other process.
- It launches the binary with `-SandshellUITestHeadless YES` (DEBUG only, see
  `UITestHeadless` in `App/SelfTest.swift`): the app never activates, skips
  the notification-permission prompt and update check, and keeps every window
  — sheets included — transparent, click-through and behind other apps.
- Tests only use the bridge, AX reads and AX actions (`perform action
  "AXPress"`, never `click`, `frontmost` or keystrokes), so nothing moves the
  mouse or steals keyboard input.
- The test workspace is a fresh temp folder configured as a plain-shell
  workspace (fast to create; never starts an agent with your account). It's
  opened with a `sandshell://open` URL handed to the test instance through the
  bridge (`open sandshell://…` would go to whichever app LaunchServices picks).
- The Settings ▸ Sandboxes lifecycle test only ever touches a sandbox named
  `sandshell-uitest-<pid>` that the runner created (on its own temp folder)
  before launching the app, by `AXIdentifier == "sandbox-row-<name>"`.
- Cleanup (`trap … EXIT`) kills the test instance, removes every
  `sandshell-uitest-*` sandbox (the lifecycle one, the test workspace's, and
  any left by a crashed run) and both temp folders, deletes the test bundle's
  defaults, and unregisters the test app from LaunchServices so
  `sandshell://` links keep opening your installed app.

Nothing in a run needs a click: the instance is an `AutomatedRun` (no
Keychain read, no notification prompt, alerts answer themselves, rebuilds
only for `/tmp` workspaces), and no Apple Events go to the test build. The
shell running the suite needs Accessibility access (for System Events' AX
reads) once, like any UI automation.

## Test files

| File | What it checks |
|---|---|
| `00_launch_and_status.applescript` | App launches; `stat` round-trips valid JSON; the `sandshell://open` URL opened the test window. |
| `02_new_session_while_building.applescript` | Runs right after the window opens: the sidebar empty state shows the sandbox build progress (or "No sessions yet"), `news` adds a session immediately even mid-build, the session goes live (real `sbx create` + terminal), and the placeholder is gone afterwards. Runs before 01 so it catches the build. |
| `01_menu_structure.applescript` | Menu bar + File menu have the expected items. Read-only. |
| `03_flat_session_order.applescript` | A second session lands at the top of the flat list, and the sidebar rows (`sidebarSessionIDs`) match the controller's session order. |
| `04_settings_sandboxes_lifecycle.applescript` | Settings ▸ Sandboxes: Stop → Run → Delete of the throwaway sandbox, confirming each state change in the UI. Skipped if the runner couldn't create it. |

The `stat` JSON's per-window entries carry `sessions` (in sidebar order),
`sidebarSessionIDs`, `isBuilding`, `activity` and `emptyState` (the sidebar
placeholder's text, or null) for these checks.

`lib/Helpers.applescript` (compiled by the runner to `lib/Helpers.scpt`, since `load script` only takes compiled scripts) holds the shared handlers (bridge calls,
JSON field extraction via `python3`, and recursive accessibility-tree search
by `AXIdentifier`/name) — loaded with `load script` from each test file.

## Extending the suite

- New AppleScript files need a `run_test` line in the runner and follow the
  `on run argv` / `return "PASS: ..."` / `error "..."` convention the runner
  expects (nonzero exit + stderr message = fail, zero exit = pass).
- If a new flow needs to disambiguate rows/buttons that repeat (another list
  view, another dynamic menu), add an `.accessibilityIdentifier(...)` in the
  SwiftUI/AppKit code rather than trying to out-guess titles or positions —
  it's a one-line, UI-invisible change and makes the test far less brittle.
- Rebuild/Kits/Mounts flows in the Sandboxes/Inspector panes aren't covered
  yet; they're natural next additions using the same
  `sandbox-row-<name>`-style identifier pattern.
