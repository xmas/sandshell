# Sandshell — Release Notes

A running log of what changed, newest first. Yes, we actually write these.

## v0.2.20 — "Talk To Me"
- **Claude sessions can be a real chat now, not a terminal.** Press ⌃⌘N (or **+ ▸ New Claude Chat**) for a native chat: proper text, tool calls as tidy cards, images inline, code highlighted, tables lined up. Any Claude session flips between chat and terminal from the toolbar and keeps the same conversation either way.
- **The composer is a real Mac text field**: emacs keys, spelling, Writing Tools and undo all work. Return sends, ⇧Return adds a line, ⎋ stops Claude mid-answer. Type `/` for Claude's commands and skills, `@` to pick a file from the workspace, or just drop files and images in.
- **It plays well with the rest of your Mac.** Click an image for Quick Look or drag it out as a file. Select text anywhere and use **Services ▸ New Sandshell Chat**. Ask Shortcuts or Spotlight to start a Claude chat. Drop files on a session in the sidebar. Edit ▸ Find (⌘F/⌘G/⌘E) searches the conversation.
- **A notification when a chat finishes** while you're looking at something else, same as terminals.
- **Pick how current your sandboxes' Claude Code is**: Settings ▸ General ▸ Sandbox Image offers Stable (Docker's release), Nightly (rebuilt daily with the current Claude Code), or any custom image.
- **No more "Failed to refresh OAuth token".** When Docker Sandboxes holds your Claude sign-in (it does after `sbx login`), every sandboxed Claude now signs in through it, so sessions stop fighting over your `~/.claude` token.
- **Quitting cleans up.** Closing, restarting or quitting a session now stops its processes inside the sandbox; they used to keep running, and a relaunch could put two Claudes on one conversation.
- **Works with sbx 0.47**, which changed `sbx ls --json` and dropped `sbx create -q`. Both had broken listing and creating sandboxes.
- **Folders are back in the inspector**: Settings ▸ Folders renames, removes, trashes and adds working directories.
- **Fixes:** opening a workspace no longer starts two `sbx create`s for the same sandbox, and a resumed Claude conversation's cost no longer reads $0.
- **Install with Homebrew**: `brew install --cask docker/tap/sbx xmas/xmas/sandshell`. Sandshell now requires macOS 27 on Apple Silicon.

## v0.2.16 — "Know Your Tokens"
- **Claude's vitals live above the terminal.** Every Claude session's title strip now shows a context-window gauge and percent, session tokens in/out, cost, and the model — the same numbers Claude Code's own footer shows, fed straight from Claude Code. Colors come from your terminal theme (and turn red as the context window fills), and each piece can be switched off.
- **Pick the model from the strip.** The model name is a menu: Fable 5.1, Opus 5.5, Sonnet 5, Haiku 4.5, or Claude's default. The choice sticks for the workspace; changing it on a live session offers to restart it on the new model and pick the conversation right back up.
- **…and the effort level, right next to it**: Low, Medium, High, Extra High, Max, or Claude's default. It shows what the live session is actually running at, sticks for the workspace, and offers the same restart-and-resume when you change it.
- **Click the readout for everything else**: context breakdown (fresh vs. cached tokens), cost with wall and API time, lines changed, plan limits (5-hour and 7-day, with reset times), and the sandbox's host, memory and load.
- **How much have I actually spent?** The same popover totals every Claude conversation on this Mac for this week, month, year and all time, priced at Docker's effective rates (Fable is billed about 35% under list) with list prices kept current from a daily price feed. Contracted rates in Claude Code's `modelPricing` setting take precedence.
- **The in-terminal status line got quiet.** Sandshell sessions now show just the path and git branch there — no whale, no memory graph — since the strip carries the rest.
- **Readout colors are yours**: Settings ▸ Terminal ▸ Claude Readout has a picker for each gauge level and label, with a one-click reset to the theme.

## v0.2.15 — "The Sidebar Grows Up"
- **The sidebar is now a flat, chronological list**, closer to how Claude Desktop shows conversations — no more digging through a folder tree to find the session you were just in. It sorts by recency and re-sorts only on real events (a session starting or finishing work), not on every timer tick, so rows never jump under your cursor. Each row got roomier too: a smaller icon, a proper two-line title-plus-details block, and the working/ready indicator moved below the title instead of hogging a side rail.
- **Folder rename/remove/add lost its home** in this pass — a "Working Directories" pane is coming to replace it; for now those actions aren't reachable from the UI (tracked, not forgotten).
- **The "+ New Session" button actually works now.** It used to disable itself while a sandbox was still building and silently eat the click — meanwhile ⌘N had no such problem. Both behave the same now.
- **A blank sidebar during a first build now shows why** — the same "Building your-workspace…" text the terminal pane shows, instead of looking broken.
- **Agent identity stopped being a fixed list of 10.** Sandshell can now represent any agent a `kind: sandbox` kit introduces, not just the built-ins — and along the way we found and fixed a real bug where a single unrecognized agent string anywhere in a workspace's saved state silently wiped its entire session list on next launch.
- **No more false "done" notifications.** When Claude Code dispatches a background subagent, its own turn ends immediately (that's how the dispatch works) — Sandshell was reading that as "the whole session is idle" and notifying you up to a minute or more before the subagent actually finished. It now reads Claude Code's own "still waiting on background agents" signal instead.
- **Pick your sandbox image channel**: Settings ▸ General now lets a workspace use Stable (Docker's release cadence), Nightly (rebuilt daily with the current Claude Code), or a custom image reference — with a Rebuild Sandboxes Now button.
- **Show Log shows the log you asked for.** It used to dump every dispatcher run ever recorded for a sandbox, including stale ones from a previous boot; now it shows only the most recent run.
- Also: the setup wizard's Kits step was silently clipping every row's leading text against a too-wide fixed frame — fixed. ⌘O's Open Workspace browser now supports ↑/↓ and Esc, not just Return.

## v0.2.14 — "Kit Inspector"
- **Kits now tell you when they broke.** Every sandbox's startup log is read after it comes up, and each kit gets a verdict: ok, warning, failed, skipped (an earlier kit aborted the chain), or still installing. Problems show up as a banner above the terminal with the actual error line, **Show Log**, and **Rebuild Sandbox** — because kits are baked in at creation and rebuilding is the only way a kit update gets loaded. The Kits pane and the debug status window show the same per-kit status.
- **Browse Docker Hub for kits.** The Kits pane has a **Browse Docker Hub…** button listing everything in `docker.io/sbx` with descriptions and pull counts; one click adds it. Hand-typed OCI references get their name and summary filled in too.
- **Default kits.** Star a kit and it's preselected in every new workspace (and turned on in the current one — the toggle stays a per-workspace opt-out). Git SSH Commit Signing, GitHub SSH, and code-server come pre-starred, so in-sandbox commits are signed like your host commits.
- **Open Workspace grew up.** ⌘O lists every folder you've ever opened with its colored icon, sortable by recent or name, filtered as you type; Return opens the top match. The sidebar folder menu and a new **File ▸ Open Recent** submenu show the recent few plus **See More…**.
- **Open New on a folder you've used before** opens it directly instead of re-running the look/mounts/kits wizard.
- **Apply & Rebuild actually rebuilds** even when the kit list is unchanged — previously it quietly re-attached, so a kit whose *contents* changed never reloaded.
- **No more stale state.** Controller state is now published *after* it's stored, so the header status, the sidebar's New Session state, and the kit banner can't lag a step behind (that one is why shells never showed the banner).
- **Chrome, de-glassed.** Built with the macOS 27 SDK, the toolbar had sprouted Liquid Glass capsules and a stuck focus ring on the sidebar toggle. Items are borderless again, the sidebar toggle is our own, and the traffic lights are centered on the toolbar row. Window titles read "folder — session" so the Window menu is usable; the settings sheet is bigger.
- Also: the AppleScript UI test suite is now in the repo (`tests/ui`, `scripts/run-ui-tests.sh`), and the DMG builder picks a Python that actually has Pillow.

## v0.2.13 — "Toolbar Glow-Up"
- **The toolbar is now an actual toolbar.** The session actions (Reveal Folder, Stop, Restart) live in a real macOS `NSToolbar` — drag them around, add/remove them, and generally rearrange your furniture via the standard customize sheet.
- **Your agent came back to the toolbar** — the agent badge, session name, folder subtitle, and the live `Working ◷ 39m 16s` timer (green while it's grinding) now sit natively up top instead of in a bolted-on bar.
- **The folder button stopped being coy.** Clicking Reveal Folder now opens the project directory itself, instead of opening the *parent* with the folder merely highlighted. Baby steps.
- **Traffic lights are back where God (Apple) intended** — top-left, no longer wandering into the sidebar.
- **Debug builds wear hi-vis.** Local dev builds get construction-tape hazard stripes pinned behind the toolbar, so you'll never again ship a screenshot of the wrong window. (Release builds stay respectable.)

## v0.2.12 — "Right-Click Yourself Before You Wreck Yourself"
- **Right-click a file path in the terminal** → Reveal in Finder / Open / Open With…. Ghostty won't make bare paths clickable, so we built the escape hatch ourselves.
- **Login links open themselves.** When a sandboxed tool copies a device-code URL to your clipboard, Sandshell notices and opens it — but only when the *whole* clipboard is a bare URL, so it won't hijack your ⌘C.
- **Error messages are finally selectable.** That ominous grey `ERROR:` used to be look-but-don't-touch. Revolutionary, we know.
- **Dev builds wear red.** A red-washed Dock icon so you stop rage-clicking the dev whale when you meant the real one.

## v0.2.11 — "Everything Must Go (Into a Drop Folder)"
- **On-demand changed-drops scan** with Finder reveal and a terminal, for when you need to know what actually moved.
- **Copy-on-write cloning** of dropped folders into `.sbx/drops/` — instant, space-free, and slightly magical (thanks, APFS).
- Drag-and-drop now records provenance, so a dropped folder remembers where it came from.

## v0.2.10 — "A Fresh Coat of Paint"
- Migrated the app icon to the shiny new Icon Composer (`AppIcon.icon`) format. Same whale, better wardrobe.

## v0.2.9 — "On a Diet"
- **~25 MB slimmer.** Transcripts are read incrementally and history is cached in SQLite instead of being hoovered into memory wholesale.
- Fixed a cursor that forgot to change back after hovering a link. Small thing, big satisfaction.

## v0.2.8 — "Links, Actually"
- **Terminal links are clickable** at last.
- Smoother terminal activity detection and drag input.
- Codex resume now reads the JSONL history directly, so picking up where you left off actually works.

## v0.2.7 — "Codex Gets a Memory"
- **Resume Codex conversations** and browse them in the History view.
- **Open a plain shell** in an agent's sandbox straight from New Session.
- **⌘F search** across the full terminal scrollback.
- **Paste clipboard images** into the terminal as file paths (saved to `.sbx/` with a 7-day auto-cleanup, because nobody likes a hoarder).
- An OS notification when a sandbox finishes working, plus a pile of paste/selection/shortcut fixes.

## Earlier (0.1.x – 0.2.6) — "The Origin Story"
The foundational era, in which a native macOS app clawed its way out of a Tauri rewrite:
- A Finder-style sidebar of folders → sessions, in-window libghostty terminals, and full sandbox lifecycle (create / start / stop / remove).
- A 53-theme OKLCH color system with a searchable picker, light/dark/system appearance, per-session terminal colors, and a whale "working" indicator.
- Multi-folder windows, per-root settings, an MCP management pane, and a Sandboxes pane.
- A History browser that resumes non-live sessions from their transcripts.
- An in-app updater, a first-install assistant, and a properly styled DMG (the one you're reading this in).
- The `sandshell` CLI, precise end-of-work detection from transcript stop reasons, and more ⌘-shortcut wrangling than anyone should have to do.
