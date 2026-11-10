# Canvas

Design work the way Claude Design does it: the agent makes screens, the
Canvas lays them out side by side as artboards, and you point at what to
change. Everything stays in the workspace as files the agent writes and reads,
so a board is versioned with the code and works with any agent.

## Shape

```
agent (in the sandbox) ──writes──▶ .sandshell/canvas/<board>/  ◀──FSEvents── Canvas pane (WKWebView per artboard)
                                                                               │
you: click an artboard, leave a note ──▶ chat message + screenshot ──▶ the same agent
```

- **A board is a folder**: `.sandshell/canvas/<board>/board.json` plus the
  artboards' files beside it. The workspace folder is mounted into the
  sandbox read-write, so the agent writes boards with its ordinary file tools.
  Nothing new crosses the sandbox boundary.
- **The Canvas is a pane**, like a session: open a board from the sidebar or
  ⌘K, split it beside the chat that's making it (`PaneTreeController`).
- **Artboards are web pages**: one `WKWebView` each, sized to the artboard,
  on a zoomable, pannable surface (`NSScrollView` magnification; its clip
  view pans past the board's edges, scrolling over a page pans the board and
  ⌥-scroll scrolls the page, dragging empty space pans). HTML, CSS,
  a React component through a small bundled runtime, an image, or a URL (a dev
  server in the sandbox).
- **Live**: a `FileWatcher` on the board folder reloads the artboards whose
  files changed, so you watch the agent work.

## board.json

```json
{
  "title": "Onboarding",
  "artboards": [
    { "id": "welcome", "title": "Welcome", "file": "welcome.html",
      "x": 0, "y": 0, "width": 390, "height": 844, "device": "iphone" },
    { "id": "welcome-b", "title": "Welcome (B)", "file": "welcome-b.html",
      "x": 450, "y": 0, "width": 390, "height": 844, "device": "iphone" },
    { "id": "app", "title": "Running app", "url": "http://localhost:5173/",
      "x": 0, "y": 950, "width": 1280, "height": 800 }
  ]
}
```

`x`/`y` are canvas points; the agent may leave them out and the Canvas lays
the artboards out in a row. Moving an artboard on the Canvas writes its
position back. Unknown keys are kept, so the format can grow.

## Teaching the agent

A skill (`canvas`) says how to make and change a board: the folder, the
format, one self-contained file per artboard, variants as siblings, how to
read a note. It's in a small Claude Code plugin the sandshell-claude kit
builds in (`/opt/sandshell/plugin`), which Sandshell's Claude chats load
per session (`_meta.claudeCode.options.plugins`) — so it's there for every
chat without touching the user's mounted `~/.claude` (sbx's `agent-skill@1`
exposes skills in the sandbox's own `~/.claude`, which Sandshell's chats
don't read: their `CLAUDE_CONFIG_DIR` is the host's). `/sandshell:canvas`
starts a board from the chat. A link to a board's file in a reply opens the
board beside the chat.

Any session can have a board: the palette icon on its sidebar row and title
strip opens it, made the first time. A chat already running is told with your
next message (`ChatSession.noteBoard`); a design session and a relaunched chat
at launch. Terminal sessions get the board but no word to the agent.

## Notes back to the agent

Turn on **Comment** at the board's corner, then click a spot or drag out an area
of a page (or ⌥-click, or right-click ▸ Add Note, without the mode; a plain
click is otherwise the page's), type a note, and **Send to Chat**: the chat gets a message naming
the board, the artboard and the element under the click (a CSS selector and
its text, from the page), with a screenshot of the artboard and the point
marked, attached like any image. **Add Another** leaves a numbered pin and
keeps going, and the notes go as one message. They go to the board's design
session, queued behind a running turn and started if it isn't yet, else the
focused chat, else any chat showing in the folder's window
(`PaneTreeController.sendNotes`). The message gives the element, and the point
or area in the page's pixels. The agent edits the file; the artboard reloads.

## Phases

1. **Viewer**: open a board as a pane; artboards from `board.json`, zoom/pan,
   titles, live reload, empty and broken-board states. Self-test scenario
   `canvas` on a fixture board.
2. **Skill**: the `canvas` skill in the kits; the agent makes a board from a
   prompt; boards listed in the sidebar.
3. **Notes**: pins and notes on artboards, Send to Chat with screenshots.
4. **Running apps**: URL artboards reach a dev server in the sandbox (sbx
   publishes the port); device frames; refresh.
5. **Arranging**: drag, duplicate, compare variants, export PNG/PDF.
