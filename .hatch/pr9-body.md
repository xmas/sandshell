This branch started as the toolbar-identity fix and became the release train for **v0.2.14, v0.2.15 and v0.2.16**, all already shipped as DMGs. It is 16 commits ahead of `main` with nothing to rebase (`main` has not moved since v0.2.13).

## What's in it

**v0.2.16 — "Know Your Tokens"**
- Claude's vitals live above the terminal: context-window gauge, session tokens, cost and model, fed from Claude Code's own status line.
- Model and effort pickers in the strip; changing one on a live session offers to restart and resume.
- Click the readout for context breakdown, cost and timing, plan limits, sandbox host stats, and all-time Claude usage across the Mac priced at effective rates.
- Readout colors are configurable in Settings ▸ Terminal.

**v0.2.15 — "The Sidebar Grows Up"**
- Flat, chronological sidebar that re-sorts only on real events.
- Agent identity is open-ended (any `kind: sandbox` kit), fixing a bug where one unrecognized agent string wiped a workspace's session list.
- No more false "done" notifications while a dispatched subagent is still running.
- Per-workspace sandbox image channel (Stable / Nightly / custom) with Rebuild Sandboxes Now.
- Open Workspace browser: fixed collapsed height, ↑/↓ selection, Return, Esc, hover state.

**v0.2.14 — "Kit Inspector"**
- Per-kit startup verdicts with a banner, Show Log and Rebuild Sandbox.
- Browse Docker Hub for kits; default (starred) kits.
- ⌘O Open Workspace browser and File ▸ Open Recent.
- Toolbar de-glassed under the macOS 27 SDK; AppleScript UI test suite added.

**Original fix (v0.2.13 regression)**
- The toolbar identity (badge, name, subtitle) went blank because the custom-view toolbar items re-parented shared views on NSToolbar's palette/sizing pass. Identity views are now built once and handed only to the inserted item.

Full notes in `CHANGELOG.md`.

## Verification
- Debug build of the branch head succeeds (xcodebuild, arm64).
- Each release was built and installed via `scripts/release.sh`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
