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

1. **A minimal built-in Apple Event test bridge** (`AppDelegate.swift`,
   `testEventClass 'Shll'`): `«event Shllstat»` returns JSON describing every
   window and session (agent, workdir, running/live state, unread flag, work
   time); `«event Shllnews»` does the equivalent of ⌘N (new session in the
   current context) and returns the same JSON. This lets the suite verify the
   real `sbx create` → container → terminal pipeline actually worked, by
   polling JSON state, instead of trying to read terminal pixel content.
2. **A handful of `.accessibilityIdentifier(...)` tags** added to
   `SandboxesPane.swift` and `InspectorView.swift` so the Settings ▸ Sandboxes
   lifecycle test (Stop/Run/Delete) can address specific rows/buttons
   reliably instead of matching on button titles that repeat across rows.

Everything else (menu structure) is read directly off the accessibility tree
by title, since menu titles are already stable, real UI.

## Safety model — read this before changing the suite

These tests drive **the one running Sandshell process** with no per-PID
disambiguation (System Events addresses processes by bundle id / name). That
only works if there's exactly one instance running, so:

- The runner **refuses to start if Sandshell is already running** (your
  interactive session), unless you pass `--force-quit`. Never assume it's
  safe to steal focus from a live session.
- It creates a brand-new, uniquely-named temp folder and opens it as an
  *additional* window via the `sandshell://open?workspace=…` URL handler —
  this never touches your real folders/roots, and every test targets that
  window by its title (the temp folder's basename) before doing anything.
- The Settings ▸ Sandboxes lifecycle test only ever touches a sandbox named
  `sandshell-uitest-<pid>` that the runner itself created via `sbx create`
  before launching the app — it looks up that one row by
  `AXIdentifier == "sandbox-row-<name>"` and never interacts with any other
  row, so real sandboxes in the list are left alone.
- Cleanup (`trap ... EXIT` in the runner) removes the throwaway sandbox and
  temp folder and quits the test instance, whether the run passed or failed,
  and sweeps any `sandshell-uitest-*` sandbox left over from a prior crashed
  run as a safety net.

If you add a test that needs to touch something persistent (a real root, a
real sandbox), stop and reconsider — it almost certainly means the fixture
setup belongs in the runner instead.

## Test files

| File | What it checks |
|---|---|
| `00_launch_and_status.applescript` | App launches; `'stat'` Apple Event round-trips valid JSON with ≥1 window. Cheapest possible "is this build alive" signal — run first. |
| `01_menu_structure.applescript` | Menu bar + File menu still have the expected top-level items. Read-only. |
| `02_new_session_via_apple_event.applescript` | Sends `'news'`, polls `'stat'` until a new session appears in the test workspace window and is reported `isLive`. Exercises the real `sbx create` + terminal pipeline. |
| `03_settings_sandboxes_lifecycle.applescript` | Opens Settings ▸ Sandboxes, Stops → Runs → Deletes the throwaway sandbox, confirming each state change in the UI. Skipped if the runner couldn't create the throwaway sandbox. |

`lib/Helpers.applescript` holds the shared handlers (Apple Event bridge calls,
JSON field extraction via `python3`, and recursive accessibility-tree search
by `AXIdentifier`/name) — loaded with `load script` from each test file.

## Extending the suite

- New AppleScript files just need to sort after `03_...` and follow the
  `on run argv` / `return "PASS: ..."` / `error "..."` convention the runner
  expects (nonzero exit + stderr message = fail, zero exit = pass).
- If a new flow needs to disambiguate rows/buttons that repeat (another list
  view, another dynamic menu), add an `.accessibilityIdentifier(...)` in the
  SwiftUI/AppKit code rather than trying to out-guess titles or positions —
  it's a one-line, UI-invisible change and makes the test far less brittle.
- Rebuild/Kits/Mounts flows in the Sandboxes/Inspector panes aren't covered
  yet; they're natural next additions using the same
  `sandbox-row-<name>`-style identifier pattern.
