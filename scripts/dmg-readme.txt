Sandshell — first-time setup
============================

Sandshell isn't code-signed yet, and macOS blocks double-clicking unsigned
helper scripts ("could not verify… is free of malware"). Running it through
Terminal avoids that. It only takes a minute:

  1. Drag "Sandshell" onto the Applications folder in this window.

  2. Open Terminal (Applications ▸ Utilities ▸ Terminal, or Spotlight "Terminal").

  3. Copy this line, paste it into Terminal, and press Return:

         bash "/Volumes/Sandshell/Sandshell Setup.command"

That removes the security quarantine from Sandshell, installs or updates the
sbx CLI (restarting its daemon if needed), signs you in to sbx, installs the
`sandshell` command-line tool, and launches the app.

After setup, you can open any folder in Sandshell from your terminal:

    sandshell                         # open current directory
    sandshell ~/my-project            # open a specific folder
    sandshell ~/project ~/data        # with a read-only extra mount
    sandshell ~/project -w ~/writes   # with a read-write extra mount

Prefer Homebrew? It installs Sandshell, the sbx CLI and the `sandshell`
command in one step, and `brew upgrade` keeps them current:

    brew install --cask docker/tap/sbx xmas/xmas/sandshell
    sbx login
