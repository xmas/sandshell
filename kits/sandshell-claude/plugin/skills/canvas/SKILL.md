---
name: canvas
description: Make or change designs on a Sandshell Canvas board — screens, mockups, UI variations, landing pages, components, as pages of design options the user sees live in Sandshell. Use when the user asks for a design, mockup, screen, wireframe, prototype, variations to compare, or "put it on the canvas", or sends a Canvas note.
---

# Sandshell Canvas

Sandshell shows a board as a canvas beside the chat, a page at a time, and
reloads each screen as you write its file. A board is a folder in the workspace:

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

A board has **pages**, one per question you're working on; a page has
**designs**, the options that answer it (A, B, C…); a design has one screen,
or several **screens** — its states or steps (A1, A2…). Sandshell shows one
page at a time, each design a row, its screens left to right; the user
switches pages from the canvas's title (`Canvas · Connections ▾`).

```json
{
  "title": "Onboarding",
  "pages": [
    { "id": "welcome", "title": "Welcome screen", "note": "How the app greets a new user",
      "designs": [
        { "id": "welcome-0", "label": "0", "title": "Today", "file": "welcome-0.html", "width": 390, "height": 844 },
        { "id": "welcome-a", "title": "Big hello", "file": "welcome-a.html", "width": 390, "height": 844 },
        { "id": "welcome-b", "title": "Bolder", "file": "welcome-b.html", "width": 390, "height": 844 }
      ] },
    { "id": "signup", "title": "Sign-up flow",
      "designs": [
        { "id": "signup-a", "title": "Email first", "width": 390, "height": 844, "screens": [
          { "id": "signup-a1", "title": "Enter email", "file": "signup-a1.html" },
          { "id": "signup-a2", "title": "Check your inbox", "file": "signup-a2.html" }
        ] },
        { "id": "app", "title": "Running app", "url": "http://localhost:5173/", "width": 1280, "height": 800 }
      ] }
  ]
}
```

- `id`s: unique on the board, stable (notes refer to a screen's `id`).
- A page: `title`, and `note` (optional): the question in a sentence, then,
  once it's settled, what was chosen (`"Chosen: B"`).
- A design: `title` (how it differs), `label` (optional: designs are lettered
  A, B, C… in order; give `"0"` to a reference of how things are now, or
  `"G + H"` to a combination). One screen: `file` or `url` on the design
  itself. Several: `screens`, each with its `title` and `file` or `url`.
- `file`: a page in the board folder. `url`: a running server instead.
- `width`/`height`: on a design, its screens' size (a screen may give its
  own). Phone 390×844, tablet 820×1180, laptop 1280×800, desktop 1440×900.
  A component: just its size. Sandshell lays the page out itself.
- The order is the order the user steps through (‹ ›, ⌘[ ⌘], ← →; ↑ ↓ go
  design to design, ⌥⌘[ ⌥⌘] page to page): pages in the order you worked
  on them, a reference design first, then A, B…; a flow's screens in order.
- Keep keys you don't know about: the user's tools may add them.
- Write the whole file each time (it's read as soon as it changes); add the
  screen's page file first, then its entry.
- An older board lists `artboards` instead (each with an `x`/`y`); it still
  opens, sorted into pages by its titles. When you next change one, rewrite
  it with `pages`.

## Screen files

- One self-contained HTML file per screen: inline `<style>` and `<script>`.
  It renders on the user's Mac, not in this sandbox, so a CDN script or font
  (Tailwind's CDN, Google Fonts, React from a CDN) works there.
- Design for the screen's size exactly; no scrollbars unless the screen
  scrolls. Use real-looking content, not lorem ipsum.
- Images: files in the board folder (relative paths), or inline SVG.
- Shared CSS for several screens can go in a file beside them
  (`<link rel="stylesheet" href="board.css">`).

## A page per question

A board is shared by the whole conversation, so it fills up with designs for
different questions (a title bar, then a loading screen…). Give each its own
page, so the user sees one question at a time:

- A new question: a new page, at the end. A later round on the same
  question: more designs on its page (the next letter), never a new page.
- A design per option, not per screen: the states or steps of one option
  (empty, loading, filled; step 1, 2, 3) are its screens.
- Name pages and designs by what they are, short: page `"Title strip"`,
  design `"One strip across the pair"`. Sandshell shows the label, so don't
  repeat it in the title.
- When the user picks an option, put it in the page's `note`
  (`"Chosen: G + H"`) and leave the other designs until they say to remove them.

## Labels

Give every option a label the user can say back to you, and show it
everywhere they might look:

- Designs are lettered A, B, C… by Sandshell (or by `label`); their screens
  are A1, A2, B1. Use those labels in ids too (`signup-b`, `signup-b2`).
- Put the label on the page itself as well — a small, quiet tag in a corner
  (it shows in screenshots and Canvas notes).
- A reference of how things are now gets `"label": "0"`, never a letter an
  option would use.
- Labels stick: adding options takes the next letter, removing one doesn't
  reletter the rest (give `label` to keep them), and a combination says
  where it came from (`"label": "G + H"`).
- Refer to options by their labels when you describe or recommend them, and
  when the user picks one, say which label you're building.

## Canvas notes

The user can point at a screen and send a note. It arrives as a message
naming the board, the screen (its `id`, "Artboard `signup-a2`") and the
element they pointed at, often with a screenshot. Change that screen's file;
the canvas reloads it.
