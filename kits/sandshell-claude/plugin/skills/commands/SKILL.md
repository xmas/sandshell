---
name: commands
description: The user can run commands themselves from Sandshell's chat composer — a line starting `&` runs on their Mac (outside this sandbox), `!` in this sandbox — and you get the output with their next message. Use whenever something has to happen on the user's Mac and not in the sandbox (Xcode, xcodebuild, xcodegen, brew, git push with their credentials, opening an app, sbx commands, anything needing the Mac's tools, files or sign-ins), when you'd otherwise tell them to "open a terminal and run …", or when they ask how to run a command themselves.
---

# Commands the user runs from the composer

This chat is in Sandshell. Its composer runs a line as a command instead of
sending it to you when it starts with a sigil:

| They type | Runs | Where |
|---|---|---|
| `&xcodegen generate` | on **their Mac**, in their login shell (zsh), as them | the session's folder on the Mac |
| `!swift test` | in **this sandbox**, `bash -l` | the session's folder (your working directory) |

The output shows in a card in the chat as it runs, and **you get it with their
next message** — "[I ran `…` on the Mac (exit 0). Its output:]" and the end
of what it printed. Don't ask them to paste it.

## When to suggest it

- **Something only the Mac can do** — you can't reach the Mac from here, so
  `&` is how the user does it in one step: building with Xcode, `xcodegen`,
  `brew`, `open`, `git push` / `gh` with their credentials, `sbx` (e.g.
  `sbx secret set …`), reading a file outside the folders this sandbox mounts.
  Instead of "open a terminal on your Mac and run …", give the line, sigil
  included, ready to paste:

  ```
  &xcodegen generate && open Sandshell.xcodeproj
  ```

- **`!` is for the sandbox**, which you can usually use yourself: suggest it
  when they want to run or watch something themselves, or when a command of
  yours was refused and they'd rather run it than allow it.

## What to know

- One line, no terminal: stdin is closed and there's no TTY, so nothing
  interactive works (password prompts, `sudo` that asks, editors, pagers,
  `ssh` that asks to trust a host). For those, tell them to use a terminal.
- `&` runs in the session's folder *on the Mac*; its path there can differ
  from yours in the sandbox. Prefer paths relative to the session's folder.
- The first `&` asks them to confirm. Every `!` and `&` is recorded in Help ▸
  Show Command Log on the Mac.
- `&` works only from Sandshell's window on the Mac — not from Remote Control
  on a phone. If they're following the chat remotely, say it can wait until
  they're at the Mac.
- You can't type these yourself: only the user's own line in the composer
  runs. Don't pretend to have run one.
