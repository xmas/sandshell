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

Canvas › Page › Design › Screen. A page is one question; its designs are
the options that answer it (lettered A, B… unless a `label` says, `0` for how
things are now); a design is one screen, or several (its states or steps,
A1, A2…). Every screen is an artboard (`CanvasBoard.Artboard`: notes, the
transcript's strip and loading all work on those).

```json
{
  "title": "Agate",
  "pages": [
    { "id": "connections", "title": "Connections", "note": "Ways in to connecting a service",
      "designs": [
        { "id": "a", "title": "A connection picked", "width": 1280, "height": 800, "screens": [
          { "id": "a1", "title": "Nothing picked", "file": "conn-a1.html" },
          { "id": "a6", "title": "GitHub", "file": "conn-a6.html" } ] },
        { "id": "now", "label": "0", "title": "Today", "file": "conn-now.html", "width": 1280, "height": 800 },
        { "id": "app", "title": "Running app", "url": "http://localhost:5173/", "width": 1280, "height": 800 } ] }
  ]
}
```

The canvas shows one page (`CanvasView.pageID`), laid out by
`CanvasBoard.layout(page:)`: a design of several screens is a row under its
heading, designs of one share a row. The pane strip beside the chat says
`Canvas · <page> ▾` (a menu of pages); ‹ › and ⌘[ ⌘] step a page's screens,
↑ ↓ its designs, ⌥⌘[ ⌥⌘] the pages; ⌘↑ (or All Pages) shows every page as a
card of pictures (`PageCard`, nothing loads). The step bar's label is a menu
of the page's designs and screens, then the other pages; View ▸ Go To is
page › design › screen.

A board made before pages lists `artboards` (with `x`/`y`); it's sorted into
pages by its titles (`CanvasBoard.organize`: "Page · Design · Screen"; a
title with no page joins the next one's; a leading label like `B ·` isn't a
page), and a page whose artboards have `x`/`y` keeps them. Unknown keys are
kept, so the format can grow.

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

Any session can have a board: the **Design** button in its pane's strip (or
Open Designer in the row's menu and the pane's ⋯) makes one the first time. A chat
already running is told with your next message (`ChatSession.noteBoard`); a
design session and a relaunched chat at launch. Terminal sessions get the
board but no word to the agent.

## Design sessions

A session with a board (`Session.board`) is a design session, and it gets a
color (`DesignColor`: teal, violet, blue, pink, green — the least used, or
picked from its row's Board Color menu). Designs from
`.sandshell/canvas/design-5` (the Chosen row):

- **Sidebar**: its mark is a palette in its color, in place of its agent's;
  it pulses while the agent draws — a write to the board moments ago, or
  during the turn still running (`WorkspaceController.drawingSessions`, a
  `FileWatcher` per board). Hovering the row shows **Board ↗**.
- **Panes**: its pane's strip and its board's carry its mark (the badge; the
  board's palette). Side by side, tops level, they're a pair, their strips
  one slight shade
  (`PaneTreeController.designPairs`): a link knob sits on their seam, pulsing
  with a light running down it while the agent draws (`DesignSeamView`); the
  board's ✕ closes both (the chat's goes), or puts the board away when
  they're the only panes.
- **Design button** (the strip, left of Chat | Terminal): once a session is
  a design it stays one; the button then shows
  the board beside it or puts it away (`Session.boardHidden`: selecting the
  chat doesn't bring it back). Closing a design's board on its own puts it
  away too.
- **Artboard strip**: with the board put away, the transcript shows, after
  each turn that wrote pages on it, a strip of those artboards — the pages
  drawn small (frames served from the board's folder only, and kept from the
  page's commands) — and a click shows the board on that artboard
  (`CanvasBoard.written`, `ChatWebTranscript.artboardStrip`).

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
