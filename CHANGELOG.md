# Sandshell — Release Notes

A running log of what changed, newest first. Yes, we actually write these.

## Unreleased
- **Less chrome, one place for everything.** The window was redesigned around one rule: each action lives in one place.
- **Type:** the whole interface uses four text styles — title, body, small and code — instead of fourteen sizes. Weight means unread; colour means status. Chat text is 13 pt.
- **Sessions keep their names.** A session is named by your first message (no longer by your latest), then by Claude's own title for the conversation once it has one; a rename still wins, and clearing it goes back. Forks remember where they came from, read "Fork of …" until you write in them, and sit under their source in the sidebar.
- **Sidebar:** every row reads the same way — the agent's badge, the title, the time (a live timer while it works), and one status line: *Needs you* (and what for), *Working* (the only spinner), *Finished* (blue until you look), *Ready* (running, green), *Stopped* (and why) or *Not running* (the row fades) — plus your first instruction under it when the title isn't that. Sessions that need you sort first, then working ones. Subagents and background tasks fold into one row under their session. The header has the workspace (▾ to switch), one + and the search field; the footer is one line saying what the sandbox sees of the folder (click for details). View ▸ Comfortable / Compact sets the row size; Status Debug and the Mac terminal moved to the Help menu.
- **Title bar:** the focused session's name, its sandbox (by name) with Stop/Start and Rebuild for the sandbox itself, and Files. A session's own Stop and Restart are in its pane.
- **Sandbox menu** (click the sandbox's name): Inspect (its image, folders, kits, network and secrets, and what was installed in it since it was made), Keep What Was Added as a Kit, Start/Stop, Restart and Rebuild.
- **Keep what you installed across rebuilds.** Sandshell looks inside a sandbox for what was added since it was made — apt packages (and the apt sources and keys added for them), pip packages, npm globals, uv and pipx tools — and saves it as a kit in the workspace (`.sandshell/kits/<sandbox>-env`), turned on, so a rebuilt sandbox installs it all again. Rebuild offers it before it starts; what can't be reinstalled (a local .deb, a binary dropped in /usr/local/bin) is listed. Nothing else — search is the sidebar's field, the Finder folder is in the pane's breadcrumb, Chat/Terminal is in the pane.
- **Pane strip:** one line that never wraps — sandbox › folder › branch (and the session's name when there's more than one pane) on the left, Chat | Terminal and split/close on the right. As a pane narrows the breadcrumb shrinks to icons, then folds into a ⋯ menu; the buttons never move.
- **Files is the right sidebar,** full height with its own header (branch · changed files), toggled with the Files button or ⇧⌥⌘0 — no longer something a pane can show. Inside it, the tree, the open file and a diff column sit side by side; hide or show the tree (⌥⌘1) and the diff column (⌥⌘2) from the header or the View menu, and make the sidebar as wide as you like.
- **Composer:** the message field is a pill with one round button — Send, or Stop while Claude is working (the only place a turn stops). Model, effort, approval mode, MCP and the cost/context readout sit under it, so everything about the next turn is in one place.
- **Chats and sessions start faster.** A chat's agent is up in about 3.3 s instead of 4.6 s on a running sandbox (launch to ready 0.4–0.75 s, was 1.0–1.3 s), and three windows restored together are ready in about 2 s instead of 5–6 s: launches go first and the window's other sandbox reads wait for them, and windows share `sbx ls` / `sbx secret ls` calls.
- **Watch a sandbox being made.** While a sandbox is built, its pane shows what sbx prints — settings, the image pulled layer by layer, kit installs — and keeps it beside a failure.
- **Edits count as changes before you save.** Typing in a file in Files marks it modified in the tree and the header's count, and its diff (against git) and the change bars beside its line numbers follow as you type.
- **Tables in chats are tables,** however wide: columns fit the chat's width and long cells wrap inside them (a wide table used to turn into a list of records); tables without outer pipes, in quotes, after a line of text or still arriving all render as grids, re-fitting when the pane is resized.
- **Fixes:** hidden pieces of a pane (the build log, the kit banner) no longer stop the window from getting smaller.

## v0.2.29 — "Steady"
- **The message field grows** with what you type, up to about half the chat's height (it had stopped at one line), then scrolls.
- **Copy your own messages** from the hover bar or the right-click menu, like replies. Hovering shows just the Copy / Fork buttons; what you copy briefly lights up.
- **Fixes:** the sidebar resizes again with a chat showing (0.2.28's centered chat column held the chat pane to its width and pinned the sidebar at its widest); the window's header is one strip over the Files inspector too, with nothing of the inspector drawn in it; the inspector's editor fills its column again instead of squeezing the code into a narrow strip; the chat no longer jitters while the sidebar slides in or out (the text keeps its width and just moves); a reply's Copy / Fork bar stays up as you move onto it, with an arrow pointer instead of the text cursor.

## v0.2.28 — "In Detail"
- **Chats read in a centered column** up to 800 points wide in a wide pane, like the Claude app — the transcript, the composer and its controls line up; the scroller stays at the edge.
- **Session Details beside each chat** (View ▸ Show Session Details, ⌥⌘I), like the Claude app's side panel, with cards you can collapse and drag into any order: **Context** (Claude Code's /context breakdown — messages, tools, MCP tools, memory, skills, the auto-compact buffer and free space — the MCP tools and memory files behind it, how far until auto-compact, and Compact Session), **Background tasks** (workflows, subagents, commands and monitors with their time and Stop; finished ones folded away), **Connectors** (the chat's MCP servers and their state) and **Environment** (the sandbox and its system, the folder and how the sandbox sees it, git branch, worktree and ahead/behind, published ports you can open, the network policy, kits).
- **Workflows** Claude runs show as background tasks and as rows under their session; open one for a window like the Claude app's: elapsed time, agents and tokens, each phase's progress, and every agent's model, tokens and time (click one to read its conversation).
- **Clone mode** (Settings ▸ Sandboxes): agents work on a private clone of the repo (sbx --clone) instead of your folder; Session Details shows the sandbox's git remote, fetches the agent's commits and says how many are new.
- **Subagents show under their session.** When Claude starts subagents, each appears beneath its session in the sidebar (a tree line, its description, type and state); the count beside the session shows or hides them (← / → too). Click one, or press Return, to read its whole conversation in a window that follows it while it works; right-click to reveal or copy its transcript.
- **More like a Mac app.** A Session menu (Stop ⌘., Restart ⌘R, Show as Chat/Terminal ⌃⌘T, Reveal in Finder ⌥⌘R, Rename…); File ▸ Reopen Closed Session (⇧⌘T), Revert to Saved, Export Conversation… (⇧⌘E) and Print… (⌘P); closing and renaming sessions undo; menu items say what they'll do (Show/Hide Files, Hide Sidebar ⌃⌘S, Close Tab/Session/Window); View ▸ Show/Hide Toolbar and Customize Toolbar…; Help ▸ Keyboard Shortcuts (⌥⌘/), Release Notes and the logs. ⌘W in Files closes the file's tab, not the session. Shortcuts like ⌘D no longer fire workspace commands from sheets and other windows.
- **Sidebar:** select several sessions (⇧/⌘-click) and close or copy them together; ⌘C copies a session's name and folder; drag a session into Terminal for its path; the filter narrows as you type (⌥⌘F; Esc clears, ↓ into the list); type to jump to a session; Return or Rename… renames it in place (and the name sticks); the selection dims when the window or list isn't focused; Reduce Motion and Increase Contrast are respected.
- **Files:** select several files; ⌘C copies them (for Finder) and their paths; Return opens; ⌘⌫ moves to the Trash; New File, New Folder, Rename (in place), Duplicate, Open With and Share in the context menu — all undoable; drop files from Finder onto a folder; open folders and open tabs are remembered. Commits copy their id and subject.
- **Settings is a window** (⌘,) instead of a sheet, and opens on the pane you used last. Sidebar and inspector widths are remembered per window.
- **Chat replies** have Copy (Markdown + rich text), Fork and Share in their right-click menu; search results copy, reveal their transcript, and drag out.
- **Agents can ask you questions in chats.** When Claude (AskUserQuestion), Codex, or an MCP server asks something mid-turn, the question appears above the composer with its options (and each option's preview), an "Other" box, Skip and Submit — Return submits, Esc skips, 1–9 pick. The session's row says "Waiting for you", you get a notification if you're elsewhere, and the transcript keeps what you answered. An MCP server's sign-in link opens in your browser.
- **Undo a turn's edits.** When Claude changes files in a chat, the turn ends with "Changed 3 files · Undo": Undo shows what it would put back, then restores those files to how they were before that message (Claude Code's checkpoints; shell-command changes aren't tracked).
- **MCP servers at a glance.** A Claude chat's footer shows "MCP 3/4" (red when one's failing); click for each server's status, what it runs, its error and its tools, with Reconnect and Enable/Disable.
- **Stop a background task** from the Background Tasks list (a chat's subagents, background commands and monitors).
- **Sandshell's own kits.** Undo and MCP status come from the new `sandshell-claude` kit, which also preinstalls the chat adapter so chats start sooner; `sandshell-codex` does the same for Codex. They're on for every workspace and can be turned off in Settings ▸ Kits (those features then hide); a workspace's existing sandboxes pick them up at their next rebuild. Published for any sbx client at github.com/xmas/sandshell-kits.
- **Chats start faster.** A spare agent waits behind the last chat, so the next new chat is ready in well under a second.
- **Sandshell sees what other apps are doing** in a conversation (through Claude Code's own session list): it knows when the Claude app is mid-answer, and "Send When It Finishes" holds your message until it's done.
- **Messages sent while Claude is working queue up** and send when the turn ends — Return no longer loses them.
- **Codex chats answer.** They sign in through sbx like `sbx run codex`, and when Codex's default model isn't available with a ChatGPT sign-in, the chat moves to one that is (and remembers it).
- **Picking up after another app is safe.** When the Claude app (or a terminal) continued a conversation, Sandshell's reload no longer lets its old agent overwrite those turns on the way out, and if the reload misses them it loads again before sending.
- **A big bug-fix pass** (about 130 fixes, each found by a reviewer and confirmed by others before it was fixed):
  - **Windows on the same folder agree:** they share sandbox bring-ups (no double builds, and Apply & Rebuild during a build gets your new mounts), the folder's look, kit drift and the selection; a "+ New" in one never reuses a session running in another; a notification opens the window running the session.
  - **Sandboxes:** a failed `sbx ls` no longer reads as "sandbox gone"; changing the primary agent keeps the sandbox names, so a Codex chat never attaches to Claude's sandbox; CLI mounts reach an open window; a rebuild never destroys a custom agent's sandbox after its kit is unregistered.
  - **Folders:** renaming one moves the folders inside it, its sessions and their Claude conversations, so they still resume; Reopen Closed Session works after a rename; the sidebar's order and "5m ago" survive a relaunch.
  - **Sidebar:** the selection stays on the same rows when the list changes; ⇧/⌘-click and Delete do the right thing with subagent and workflow rows (Delete never closes the parent session); renaming in place isn't interrupted, and an unchanged name isn't saved; no more full reloads every 3 seconds while a subagent runs.
  - **Files:** Undo of a file operation works after the Files pane closes; drops land in the folder under the pointer and keep their names; ⌘/⇧-click selects without opening; renaming in place survives refreshes, and Esc puts the old name back; Trash closes the files' tabs and Undo reopens them; saving a trashed file asks instead of recreating it; Print prints what's shown.
  - **Chats:** a background chat's question no longer takes the keyboard from the chat you're typing in; numbers in questions can't crash the app; a queued draft is merged, not replaced; dropped files that can't be copied say so; exported conversations are named after the session.
  - **Keyboard:** ⌘Q and the app's shortcuts work in host-terminal windows; ⌘Z reaches Edit ▸ Undo from a terminal; Next/Previous Pane moves the keyboard, not just the ring; ⌥⌘F filters sessions instead of opening terminal Find.
  - **Settings** keeps unapplied edits when it's brought forward again; several MCP servers finishing sign-in while Settings is closed are all enabled; an MCP server that fails to add says why on its row; an unreadable config.json or state.json is kept aside and the window says so.
  - **Terminals in folders reached by two paths** (a folder saved as /private/tmp/x, its sandbox mounting /tmp/x, or through a symlink) start in the right place instead of ending after a few seconds; the sandbox chip no longer calls such a folder "not shared".
  - **Codex:** a sandbox whose sign-in placeholder came out empty (e.g. while the disk was full) repairs itself.
  - **Accessibility and polish:** color and icon pickers, symbol buttons and status dots are real, labelled controls for VoiceOver and Full Keyboard Access; counts and lists follow your locale; relative times keep counting on their own.
- **Fixes:** Files works in folders under /tmp (the changed list, badges and Changes were empty there); the editor no longer takes the keyboard when files change on disk; a new sandbox with kits isn't used until its kit setup finishes (a chat started in it could die silently); an unreadable workspace config is kept, not overwritten; toolbar Stop/Restart can't reach a session a pane no longer shows; a session dragged into a pane while starting shows up when it's ready; commit lists in Files handle accented names and merges; Search shows custom agents' icons; Open Quickly highlights the right letters in names with characters like İ; a commit picked in Files stays picked when the list refreshes; a chat that reconnects keeps a waiting message's pasted images; Undo can't pick an earlier turn with the same words; a model the agent refuses no longer shows as chosen; and a chat can't crash the app by answering an agent that just quit; closing a window or quitting asks about unsaved file edits; a failed save no longer closes the tab; saving asks before overwriting a file an agent changed meanwhile; typing in Files isn't reset when other files change; a file that grows past 4 MB shows in Quick Look instead of as an empty editable copy; content search (?…) finds files with accented names; rebuilding one sandbox no longer ends the other sandboxes' sessions; "Couldn't restore" asks once; a second window on the same folder no longer restarts (and ends) a session running in the first; and one look for choosers, badges, popovers, alerts and +/− counts throughout.

## v0.2.27 — "Ripples"
- **The empty chat's sea is calmer.** No more bubble: move over the sea creatures and the ones you pass color in with a quick swish while rings of water ripple out from under them and fade. A moment later everything is gray and still again.

## v0.2.26 — "Line by Line"
- **Commits in Files.** Under the file tree: **All changes** on your branch, **Uncommitted changes**, and each commit since the branch left main (the last 20 when you're on main). Pick one and the tree lists just the files it touched, with +/- counts; open a file for that commit's diff.
- **Tell the agent what to change, right in a diff.** Diffs show line numbers; click one, type what should change, press Return. The session gets the file, the line, its code and your note — sent in a chat, typed into a terminal agent's prompt.
- **Codex chats sign in.** A Codex chat now signs in through sbx the way `sbx run codex` does, instead of saying it has no OpenAI credential.
- **New chats start in Auto mode** where the agent offers it; a resumed conversation keeps its own mode. And you can't type into a chat until its agent is ready.
- **An empty pane has New Session**, the same menu as the sidebar's +, opening right there.
- **Agent kits stay with their agent.** A sandbox's own agent kit (Droid, say) no longer shows up as a kit to adopt, and never goes into other agents' sandboxes — which had Kiro and OpenCode failing to start.
- **Browse Docker Hub works again** (Hub refused the second page of results).
- **Fixes:** the session name in the toolbar uses its full width; pane dividers start below the toolbar; the sidebar's "Building…" no longer sits on top of your sessions; the sea of creatures fits a narrow pane.

## v0.2.25 — "Room to Breathe"
- **Windows resize again.** In 0.2.24 a window with a chat could get stuck very tall and refuse to shrink, because the empty chat's sea asked for far more height than it needed, even after the conversation started. It now just fills whatever space the chat has.

## v0.2.24 — "Tables Turned"
- **Tables read properly in chat.** A small table is a tidy grid in the chat's own font, header in bold over a rule. A wide one, with long cells, becomes one entry per row, its first cell as the heading and each column as a labelled line that wraps on its own. Bold, `code` and escaped pipes render in both, and it's all still selectable text. (Markdown previews in Files get the same tables.)
- **The sea follows your pointer.** Move over the empty chat's sea creatures and the ones nearby color in and swim round in a bubble, no click needed. The sea now spans the whole empty chat, so bubbles aren't cut off at the edge.
- **A long session name no longer runs over the toolbar.** It's cut short with an ellipsis instead of drawing across the status and the buttons beside it.

## v0.2.23 — "Same Model, Both Ways"
- **A chat and a terminal agree on the model.** Claude chats now use the same model and effort menus as terminals, up in the pane's title strip, and start on the model you picked for the workspace — including ones the chat didn't list before, like Sonnet 5.5. Switching models picks the conversation right back up; effort changes take effect immediately.
- **Usage in chat mode.** The context gauge, cost and model readout now show for chats too, same as terminals.
- **Codex, Gemini and shell sandboxes no longer fail on the code-server kit.** Kits made for one agent (code-server needs Claude) are left out of other agents' sandboxes instead of breaking them, and the Kits pane marks them "Claude only". A long error now wraps inside the pane.
- **The empty chat is a quiet sea** of black-and-white sea creatures. Click it and the ones nearby take on color and swim round in a bubble for a moment.
- **Pasted images stay out of your project.** An image pasted into a terminal session is saved inside the sandbox now, not as a `paste-*.png` in your folder (chats never needed a file).
- **Files reads better in a narrow pane:** the filter has its own row, clear of the toolbar, with the changed-files toggle ("33 changed") below it and more room around the footer.

## v0.2.22 — "Pick Up Where It Left Off"
- **Chat is the default.** ⌘N and + ▸ New Claude / Codex / Gemini start a chat; the terminal versions live under + ▸ In Terminal. Each pane has its own Chat ⇄ Terminal switch in its title strip, same conversation either way.
- **A chat follows a conversation that's still going elsewhere.** Open a conversation you're also having in the Claude app (or Claude Code in a terminal) and its new turns show up in Sandshell as they're written, under "Continued in the Claude app". When you reply from Sandshell, Claude reloads the conversation first so it knows what was said there; if the other app is still mid-answer, Sandshell asks before starting a second line of conversation alongside it.
- **Chats come back after the Mac sleeps.** If a chat's agent drops while your laptop is closed (or for any other reason), Sandshell reconnects it on its own — when it wakes, or when you open the chat — and picks the conversation right back up. No more flipping to Terminal and back; if an agent keeps dropping, Send turns into **Reconnect**.
- **Tool calls fold into one line**, like the Claude app: "Ran git status ›", "Ran 3 commands, read a file ›" (with any failures in red). Click one to see the commands and their output.
- **An empty chat has dolphins.** A little sea where the app icon used to be: dolphins swimming by and leaping out with a splash, a shell on the sand. It holds still with Reduce Motion on.
- **Every pane has buttons**: Files, Split Right, Split Down and Close in its title strip, and an empty pane offers Show Files / Close Pane. Files always opens beside a session, never in its place.
- **See where a session runs at a glance.** The title strip shows the sandbox (click for what that Linux VM can see and do), the folder, and the git branch with +/- line counts; the Claude readout makes room for them in a narrow pane instead of squeezing them out.
- **Files knows whose files these are**: the footer says whether the session's sandbox can write to them, a **Changed** toggle lists only the changed files, and Open Quickly highlights its pick properly.
- **Hover a reply to Copy it or Fork to New Chat** from that point. File paths and links in a conversation are clickable — files open in Files at the line, even with spaces in the name.
- **Search goes deeper**: it reads up to 2,000 past conversations in this workspace, searches their latest text as well as their opening, and a conversation that was a chat comes back as a chat. The toolbar's Search button now shows up for everyone.
- **A session that can't start says why** (a kit that's gone, say) with Try Again and Edit Kits…, instead of retrying forever.
- **Fixes:** the Files inspector's tree could collapse to nothing at its narrowest width; one chat could start two copies of its agent; Settings ▸ Sandboxes ▸ Run now flips to Stop once the sandbox is up; rebuilding a custom agent's sandbox whose kit isn't registered no longer deletes it first; a kit that defines an agent, added under Kits, becomes an agent; chats that stop on a sign-in error say Stopped, not Ready; Open Quickly and @-mentions work in folders under /tmp.

## v0.2.21 — "Side By Side"
- **Know what's running in the background.** When Claude sends a subagent off, starts a background command or sets a Monitor, the session's title strip shows "2 running"; click it for each task's elapsed time, latest step and result, and a background command's output read straight from the sandbox. Sidebar rows say "1 in background", **Window ▸ Background Tasks** (⌥⌘B) lists every session's at once, and you get a notification as each one finishes (tap it to jump there). Works for terminal sessions and chats alike.
- **One Search for everything** (⇧⌘F, or the sidebar's Search button): open sessions and past conversations in this workspace together, ranked by title, folder, then text, with the match highlighted. Arrow keys and Return work; picking an open session focuses the pane it's already in.
- **Split the window.** ⌘D splits right, ⇧⌘D splits down, ⌥⌘W closes a pane, ⌥⌘[ / ⌥⌘] move between them and ⌃⌘= evens them out. Drag a session from the sidebar onto a pane's edge to open it there; dividers drag, and the layout comes back next launch.
- **Files, right next to your sessions.** The Files pane (⌥⌘0) shows the session's folder as a tree with git badges, an editor that saves with ⌘S and notices when Claude changes a file under you, a Markdown preview set in New York, and a Changes view with per-hunk **Stage**, **Unstage** and **Revert…**. Open it as a pane beside a chat or terminal with **View ▸ Open Files in Split** (⇧⌥⌘0). ⇧⌘O is Open Quickly, ⌘L is Go to Line, and `?query` in the filter searches file contents.
- **Codex and Gemini chats.** File ▸ New Codex Chat / New Gemini Chat run them natively over ACP, same as Claude. They sign in through Docker Sandboxes: if there's no `openai` / `google` secret yet, the chat says exactly which `sbx secret set` to run.
- **Bring your own agent.** Settings ▸ Agents registers any `kind: sandbox` kit as an agent with its own name, icon and color, and it shows up in the New Session menus.
- **Adding a kit no longer rebuilds the sandbox** when Docker Sandboxes can add it in place (`sbx kit add`); kits that can't be added that way still rebuild. If a sandbox picked up a kit outside Sandshell, a banner offers to adopt it into the workspace instead of silently dropping it on the next rebuild.
- **Fixes:** ⌘[ / ⌘] switch sessions again (they had started jumping panes); ⌘N in a plain-shell workspace makes a new shell instead of reselecting the first one; pressing Stop in a chat really stops the text; the sidebar's settings/terminal/log buttons and sandbox rows work with VoiceOver; Sandshell stops copying your Keychain sign-in into `~/.claude` when Docker Sandboxes already holds it.

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
