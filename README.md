# Sandshell

A Mac app for running AI coding agents — Claude Code, Codex, Gemini and
others — in Docker Sandboxes (the `sbx` CLI).
Each workspace folder gets its own window: a sidebar of sessions, chats and
terminals side by side in split panes, and the folder's files, diffs and
commits in a sidebar of their own.

## Requirements

- macOS 27 on Apple Silicon
- [Homebrew](https://brew.sh)
- A Docker account (for `sbx login`)

## Install

```bash
brew install --cask docker/tap/sbx xmas/xmas/sandshell
```

This installs the `sbx` CLI (if you don't have it) and Sandshell, and links the
`sandshell` command-line helper.

**Why both names:** Homebrew 7 only loads casks from third-party taps you trust.
Naming a cask in full on `brew install` taps its tap and trusts that cask, so
name both — Sandshell's and sbx's, which Sandshell depends on — even if sbx is
already installed. If Homebrew says *Refusing to load cask … from untrusted
tap*, trust them yourself and install again:

```bash
brew trust --cask docker/tap/sbx xmas/xmas/sandshell
```

(`brew trust xmas/xmas` trusts everything in the tap instead.)

**Gatekeeper:** Sandshell isn't code-signed or notarized yet. The cask clears
the download's quarantine flag, so it opens normally; if macOS still refuses,
Control-click Sandshell in Applications, choose **Open**, and confirm once.

Then sign in to sbx once, and open Sandshell:

```bash
sbx login
```

```bash
open -a Sandshell
```

The first window walks you through a workspace: the folder to work in, its
look, what else to mount into the sandbox, and which kits to add. The sandbox
is built the first time you start a session there (Sandshell shows sbx's
progress while it is).

### Without Homebrew

Download the DMG from the
[latest release](https://github.com/xmas/homebrew-xmas/releases?q=sandshell),
drag Sandshell to Applications, then double-click **Sandshell Setup.command**
in the DMG. It clears the download quarantine (the app isn't notarized),
installs or updates the `sbx` CLI, runs `sbx login`, links the `sandshell`
helper and opens Sandshell.

## Update

Sandshell checks for new versions itself and offers to update. Or:

```bash
brew update && brew upgrade --cask xmas/xmas/sandshell
```

## Uninstall

```bash
brew uninstall --cask xmas/xmas/sandshell
```

Your sandboxes are sbx's: list them with `sbx ls` and remove any with
`sbx rm <name>`. Each workspace keeps its Sandshell settings in a
`.sandshell` folder inside it.

## Build from source

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`):

```bash
xcodegen generate
```

```bash
xcodebuild -project Sandshell.xcodeproj -scheme Sandshell -configuration Debug -derivedDataPath build -destination 'platform=macOS,arch=arm64' build
```

```bash
open build/Build/Products/Debug/Sandshell.app
```

Tests, the architecture and release steps are in [CLAUDE.md](CLAUDE.md) and
[RELEASING.md](RELEASING.md); what changed in each version is in
[CHANGELOG.md](CHANGELOG.md).
