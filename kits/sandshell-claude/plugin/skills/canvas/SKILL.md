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
  left to right in order; add them only to make rows (e.g. a row per flow).
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

## Variations

Make variants as sibling artboards (`hero`, `hero-b`, `hero-c`) with titles
that say how they differ, so the user compares them side by side. Keep the
one they pick; remove the rest when they say so.

## Canvas notes

The user can point at an artboard and send a note. It arrives as a message
naming the board, the artboard (its `id`) and the element they pointed at,
often with a screenshot. Change that artboard's file; the canvas reloads it.
