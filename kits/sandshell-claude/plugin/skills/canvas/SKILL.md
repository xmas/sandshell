---
name: canvas
description: Make or change designs on a Sandshell Canvas board — screens, mockups, UI variations, landing pages, components laid out side by side as artboards the user sees live in Sandshell. Use when the user asks for a design, mockup, screen, wireframe, prototype, variations to compare, or "put it on the canvas", or sends a Canvas note.
---

# Sandshell Canvas

Sandshell shows a board as a canvas of artboards beside the chat, and reloads
each artboard as you write its file. A board is a folder in the workspace:

```
.sandshell/canvas/<board>/
  board.json
  welcome.html
  welcome-b.html
```

Use a short kebab-case board name (`onboarding`, `pricing-page`). Make the
folder and files with your ordinary file tools; the user opens the board with
View ▸ Open Board in Sandshell (say so when you make a new one).

## board.json

```json
{
  "title": "Onboarding",
  "artboards": [
    { "id": "welcome", "title": "Welcome", "file": "welcome.html", "width": 390, "height": 844 },
    { "id": "welcome-b", "title": "Welcome — bolder", "file": "welcome-b.html", "width": 390, "height": 844 },
    { "id": "app", "title": "Running app", "url": "http://localhost:5173/", "width": 1280, "height": 800 }
  ]
}
```

- `id`: unique, stable (notes refer to it). `title`: what the user sees above it.
- `file`: a page in the board folder. `url`: a running server instead.
- `width`/`height`: the artboard's size in points. Phone 390×844, tablet
  820×1180, laptop 1280×800, desktop 1440×900. A component: just its size.
- `x`/`y` (optional): canvas position. Leave them out and artboards line up
  left to right in order; add them to make rows (a row per flow, an area per
  topic: see below).
- The list's order is the order the user steps through them (the canvas's
  ‹ › buttons, ⌘[ ⌘], ← →): keep it the order to read them in — a topic's
  heading, then its options, A before B, a reference (`0`) first.
- Keep keys you don't know about: the user's tools may add them.
- Write the whole file each time (it's read as soon as it changes); add the
  artboard's page first, then its entry.

## Pages

- One self-contained HTML file per artboard: inline `<style>` and `<script>`.
  It renders on the user's Mac, not in this sandbox, so a CDN script or font
  (Tailwind's CDN, Google Fonts, React from a CDN) works there.
- Design for the artboard's size exactly; no scrollbars unless the screen
  scrolls. Use real-looking content, not lorem ipsum.
- Images: files in the board folder (relative paths), or inline SVG.
- Shared CSS for several artboards can go in a file beside them
  (`<link rel="stylesheet" href="board.css">`).

## One area per topic

A board is shared by the whole conversation, so it fills up with designs for
different questions (a title bar, then a loading screen…). Keep each topic
apart, so it's clear at a glance which artboards answer which question:

- Each topic gets its own area: a row (or a block of rows) of its own, below
  the last one, with a clear gap between areas. Lay boards with more than one
  topic out with `x`/`y`; never let a new topic's artboards continue an older
  topic's row.
- Start each area with a heading artboard (about 360×200) — a page with the
  topic's name, the question in a sentence, and when it's settled, which option
  was chosen (`"Chosen: G + H"`). Give it an id like `topic-rebuild`.
- Prefix each artboard's title with the topic, short (`"Rebuild · G · Steps
  beside the log"`), and keep its id under it (`rebuild-g`), so a note or a
  title alone says which question it belongs to.
- When the user picks an option, update that topic's heading artboard and mark
  the chosen artboard's title (`✓`); leave the others until they say to remove them.
- Put a later round on the same question in the same area (a new row under
  it), not in a new one.

## Variations

Make variants as sibling artboards (`hero`, `hero-b`, `hero-c`) with titles
that say how they differ, so the user compares them side by side. Keep the
one they pick; remove the rest when they say so.

Give every option a label the user can say back to you, and show it
everywhere they might look:

- A letter per option (A, B, C…), or a number when there are many (1–12).
  When an option has several screens, number them within it: A1, A2, B1.
- Put the label first in the artboard's title (`"B · Bolder hero"`), in its
  id (`hero-b`, `signup-b2`), and on the page itself — a small, quiet tag in
  a corner (it shows in screenshots and Canvas notes).
- A reference artboard of how things are now gets `0` or `Now`, never a
  letter an option would use.
- Labels stick: adding options takes the next letter, removing one doesn't
  reletter the rest, and a combination says where it came from
  (`"G + H · Steps beside the log"`).
- Refer to options by their labels when you describe or recommend them, and
  when the user picks one, say which label you're building.

## Canvas notes

The user can point at an artboard and send a note. It arrives as a message
naming the board, the artboard (its `id`) and the element they pointed at,
often with a screenshot. Change that artboard's file; the canvas reloads it.
