# Building, testing and releasing a Mac app from a sandbox, through Xcode

How Sandshell's agents build, test, run and release a macOS app from inside an
`sbx` sandbox, which is Linux and has no Swift. The Mac's own Xcode does the
work, and the agent drives it over Xcode's MCP bridge. This is the recipe for
setting it up in another app.

Two scripts make it work. Copy them and change a few names:

| File | Runs | What it does |
|---|---|---|
| `scripts/xcode-sandbox.py` | in the sandbox | Talks MCP to Xcode: build, test, run, start a release |
| `scripts/xcode-release.sh` | on the Mac, as a build phase of a `Publish` scheme | Turns "build Publish" into a release, confirmed in a dialog on the Mac |

## How it fits together

```
sandbox (Linux)                         Mac
───────────────                         ───
xcode-sandbox.py ──MCP over HTTP──▶ sbx MCP gateway ──▶ xcrun mcpbridge ──▶ Xcode (project open)
  build / test / RunProject                                                    │
  release 1.2.3: writes .release-request,                                      ▼
  switches Xcode to Publish, builds it ─────────────────────────▶ Publish's build phase:
                                                                 xcode-release.sh
                                                                   reads .release-request
                                                                   starts itself detached, with a clean env
                                                                   dry run → dialog "Publish 1.2.3?" → release.sh
                                                                   progress → release.log
```

The checkout is mounted into the sandbox, so the sandbox and the Mac see the
same files. That shared folder is how they talk: `.release-request` goes one
way and `release.log` comes back.

## One-time setup on the Mac

1. **Register Xcode's MCP bridge with sbx, then load it into the sandbox.**
   ```sh
   sbx mcp add xcode --command xcrun --args mcpbridge
   sbx mcp load xcode --sandbox <sandbox-name>
   ```
   Xcode has to be running with the project open. The first time a tool is
   called, Xcode asks whether to allow the connection.
2. **Generate the project, if you use XcodeGen.** Run `xcodegen generate`
   after any change to `project.yml`, including a new source file. The
   sandbox can't run it, so the agent asks you to.
3. **Sign `gh` in and keep the tap clone handy.** The release runs as you, on
   the Mac, with your GitHub login. The sandbox has no GitHub credentials, so
   it can't push. The release pushes for you.

## In the sandbox: `xcode-sandbox.py`

```sh
scripts/xcode-sandbox.py build                 # build app + tests; prints errors, exits 1 on failure
scripts/xcode-sandbox.py test                  # build, then every suite in batches
scripts/xcode-sandbox.py test FooTests BarTests
scripts/xcode-sandbox.py log warning           # the last build's warnings
scripts/xcode-sandbox.py call RunProject '{"workspaceIdentifier": "…"}'   # launch the Debug build
scripts/xcode-sandbox.py tools                 # every tool Xcode offers
scripts/xcode-sandbox.py release 1.2.3         # start a release (asks on the Mac)
```

What it does, and the traps it works around:

- **It speaks MCP itself, over plain HTTP.** It POSTs JSON-RPC to
  `http://mcp-gateway.docker.internal/` with `Authorization: Bearer
  proxy-managed`. The sandbox's proxy resolves that host and adds the real
  credentials.
  - It calls `initialize`, then `notifications/initialized`, then the
    gateway's own `mcp-add` tool with `{"name": "xcode"}`. Until that last
    call the session only offers the gateway's own tools.
  - It keeps the `Mcp-Session-Id` in `/tmp` and opens a new session on a 400
    or 404, because gateway sessions expire.
  - Answers can come back as SSE (`data:` lines) or as plain JSON. It accepts
    both.
- **Every tool needs a `workspaceIdentifier`.** It gets one from
  `XcodeListWorkspaces` by finding the line with your `.xcodeproj` name.
- **Never trust a quiet answer.**
  - `BuildProject` returns an empty response, so the result comes from
    `GetBuildLog`: `buildResult` contains "succeeded" and `buildIsRunning` is
    false. It prints `emittedIssues` once each.
  - The first `RunSomeTests` after a build can also return nothing, so it
    retries.
  - A run passes only if its own `counts` show `failed == 0` and
    `passed > 0`.
- **The gateway ends a call after about a minute, while Xcode keeps going.**
  A long test run looks like "no result", so `test` with no names runs the
  suites in batches. It finds the suite names by scanning the test sources,
  puts known-slow suites in batches of their own, and runs the rest 40 at a
  time.
  - A "Test 'X' not found" answer means a helper type looked like a suite.
    The script drops it from the batch and retries.
- **`RunProject` launches the Debug build in Xcode.** Xcode stops the
  previous run itself.

To adapt it, change `PROJECT` (the `.xcodeproj` name), `TARGET` (the
unit-test target), the test folder in `suites()`, `SLOW`, and the scheme name
that `release()` switches back to.

## Releases: the `Publish` scheme

MCP lets the agent build a scheme but not run a command on the Mac, so the
release is a build: an aggregate target whose only build phase is
`xcode-release.sh`. In XcodeGen:

```yaml
aggregateTargets:
  Publish:
    buildScripts:
      - name: Release
        script: '"$SRCROOT/scripts/xcode-release.sh"'
        basedOnDependencyAnalysis: false   # run on every build
    settings:
      base:
        ENABLE_USER_SCRIPT_SANDBOXING: NO  # it needs the whole checkout, gh, git

schemes:
  Publish:
    build:
      targets:
        Publish: all
```

Add `.release-request` and `release.log` to `.gitignore`.

**Starting a release** (`xcode-sandbox.py release 1.2.3`):

1. It checks that `XcodeListSchemes` includes `Publish`. If not, the project
   wasn't regenerated.
2. It writes the version to `.release-request` in the checkout.
3. It switches Xcode to `Publish` (`XcodeSwitchScheme`), runs `BuildProject`,
   then switches back to the app's scheme in a `finally`, so Xcode isn't left
   on Publish.
4. If `.release-request` still exists, the build phase never read it, so
   nothing started. The script says so and fails.

**The build phase** (`xcode-release.sh`, run by Xcode):

1. With no `.release-request` it does nothing, so building Publish by
   accident is harmless. Otherwise it reads the version, deletes the request,
   and checks it looks like `X.Y.Z`.
2. It starts itself again, detached, then returns, so the build finishes in
   seconds:
   ```sh
   nohup /usr/bin/env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" LANG="$LANG" \
     /bin/zsh -lc 'exec "$0" --run "$1"' "$root/scripts/xcode-release.sh" "$version" >> release.log 2>&1 < /dev/null &
   disown
   ```
   - It runs outside the build because the release regenerates the project
     Xcode has open and runs its own `xcodebuild`.
   - `env -i` plus a login shell keeps Xcode's build settings (`SDKROOT`,
     `CONFIGURATION`, `BUILT_PRODUCTS_DIR`, …) out of that build, while
     still giving it your PATH, `gh` and `git`.
3. The detached run checks `gh auth status`, updates the tap clone, and
   **rehearses** with `release.sh --dry-run`: a real build and DMG, with
   nothing published.
4. It **asks on the Mac** with an `osascript` dialog, "Publish 1.2.3?",
   whose default button is Cancel. The dialog gives up after 900 seconds and
   only an explicit **Publish** goes ahead. A timeout or Cancel ends the run
   with "not confirmed".
5. It runs `release.sh <version>`: bump the version, regenerate, build,
   make the DMG, create the GitHub release, update the Homebrew cask, then
   commit, tag and push from the Mac.
6. The log's last line is always `RELEASE FINISHED <exit code>`, with a
   reason when it fails. The agent waits for that line, for example
   `until grep -q "RELEASE FINISHED" release.log; do sleep 5; done`, and
   reports it.

The dialog prevents accidental publishing; it is not a security boundary. A
sandbox that can write the checkout can also change the script Xcode runs.
Only start a release when the person asks for one.

## Debug runs that don't collide with the installed app

When the agent launches the app (`RunProject`), the debug build must not
share anything with the copy the person is using:

- **A separate bundle id for Debug**, in `project.yml` under the Debug
  configuration's `PRODUCT_BUNDLE_IDENTIFIER: com.example.app.debug`. That
  gives it its own defaults, saved windows, keychain items and notifications.
- **Launch arguments in the scheme's run action** (`commandLineArguments`)
  that switch on a debug profile: state in a separate folder, separate
  backing resources (for Sandshell, sandboxes named `<name>-debug`), and only
  the windows a test needs.
  - Use keys of your own (`-AppDebugProfile YES`), not ones the app already
    reads. Launch arguments become defaults for every defaults suite, and the
    scheme's test action passes them on to unit tests too.
- Unit tests that host the app should notice they're running under XCTest
  (`XCTestConfigurationFilePath` in the environment), turn the debug profile
  off, and open no windows.

## Telling the agent

Put a short version in the project's `CLAUDE.md` (or `AGENTS.md`) so every
session follows it:

```markdown
## From inside a sandbox
The sandbox has no Swift; builds and tests go through the Mac's Xcode (MCP bridge;
the project must be open in Xcode):

    scripts/xcode-sandbox.py build
    scripts/xcode-sandbox.py test [Suites…]
    scripts/xcode-sandbox.py call RunProject '{"workspaceIdentifier": …}'   # debug run

A new source file or a project.yml change needs `xcodegen generate` on the Mac first; ask.
`scripts/xcode-sandbox.py release <version>` starts a release (the Mac asks first; progress
in release.log, ending "RELEASE FINISHED <code>"). Only when asked. The sandbox can't push:
the release pushes from the Mac.
```
