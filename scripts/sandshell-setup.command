#!/bin/bash
# Sandshell setup — run in Terminal (double-click this file):
#   1. remove the Gatekeeper quarantine from the (unsigned) app
#   2. install the sbx CLI, or update it if a newer version is available
#      (restarting the sandboxd daemon when sbx is upgraded)
#   3. sign in to sbx
#   4. install the `sandshell` command-line tool to /usr/local/bin
# Then launch Sandshell. Shipped inside the Sandshell DMG.
set -u

APP="/Applications/Sandshell.app"
echo "── Sandshell setup ──────────────────────────────────────────"

# 1. De-quarantine so the unsigned app opens without the right-click dance.
if [ -d "$APP" ]; then
  echo "→ Removing Gatekeeper quarantine from Sandshell…"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || sudo xattr -dr com.apple.quarantine "$APP"
else
  echo "⚠︎  $APP not found. Drag Sandshell into your Applications folder first, then re-run this."
fi

# 2. Homebrew (install if missing), then put it on PATH for this session.
if ! command -v brew >/dev/null 2>&1; then
  echo "→ Homebrew not found — installing it…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$([ -x /opt/homebrew/bin/brew ] && /opt/homebrew/bin/brew shellenv || /usr/local/bin/brew shellenv)"
fi

# 3. Install sbx, or update it if Homebrew has a newer version. When sbx is
#    upgraded, restart the sandboxd daemon so it runs the new binary.
if ! command -v sbx >/dev/null 2>&1; then
  echo "→ Installing sbx…"
  brew install sbx
else
  echo "→ Checking for an sbx update…"
  brew update >/dev/null 2>&1 || true
  if [ -n "$(brew outdated sbx 2>/dev/null)" ]; then
    echo "→ Updating sbx ($(sbx version 2>/dev/null | head -1))…"
    daemon_was_running=no
    sbx daemon status >/dev/null 2>&1 && daemon_was_running=yes
    brew upgrade sbx
    if [ "$daemon_was_running" = yes ]; then
      echo "→ Restarting the sandboxd daemon to pick up the new sbx…"
      sbx daemon stop  >/dev/null 2>&1 || true
      sbx daemon start >/dev/null 2>&1 || true
    fi
  else
    echo "→ sbx is already up to date ($(sbx version 2>/dev/null | head -1))."
  fi
fi

# 4. Enable MCP so the sandbox gateway exposes dynamic discovery (mcp-find /
#    mcp-add). SBX_MCP_URL is read by sandboxd at startup, so persist it and
#    restart the daemon (it auto-starts again on the next sbx call).
GATEWAY="https://gateway.docker.com"
echo "→ Enabling MCP (SBX_MCP_URL=$GATEWAY)…"
if ! grep -q "SBX_MCP_URL" "$HOME/.zshrc" 2>/dev/null; then
  printf '\n# Docker Sandboxes MCP gateway\nexport SBX_MCP_URL=%s\n' "$GATEWAY" >> "$HOME/.zshrc"
fi
export SBX_MCP_URL="$GATEWAY"
sbx daemon stop >/dev/null 2>&1 || true

# 5. Sign in to sbx (opens a browser).
echo "→ Signing in to sbx…"
sbx login

# 6. Install the `sandshell` command-line tool.
CLI="$APP/Contents/Resources/sandshell"
if [ ! -f "$CLI" ]; then
  echo "⚠︎  sandshell CLI not found inside Sandshell.app — skipping."
else
  LINK=/usr/local/bin/sandshell
  if [ "$(readlink "$LINK" 2>/dev/null)" = "$CLI" ]; then
    echo "→ sandshell already linked. ✓"
  else
    echo "→ Installing sandshell command to /usr/local/bin…"
    mkdir -p /usr/local/bin 2>/dev/null || sudo mkdir -p /usr/local/bin
    ln -sf "$CLI" "$LINK" 2>/dev/null || sudo ln -sf "$CLI" "$LINK"
    echo "→ sandshell → $CLI"
  fi

  # Verify the command is on PATH so the user can actually call it.
  if command -v sandshell >/dev/null 2>&1; then
    echo "→ sandshell is on PATH. ✓"
  else
    echo ""
    echo "⚠︎  /usr/local/bin is not on your PATH."
    echo "   'sandshell' won't be found in new Terminal windows until that's fixed."
    echo ""
    PROFILE="$HOME/.zprofile"
    printf "   Add /usr/local/bin to PATH in %s now? [y/N] " "$PROFILE"
    read -r reply
    if [[ "${reply:-n}" =~ ^[Yy] ]]; then
      printf '\nexport PATH="/usr/local/bin:$PATH"\n' >> "$PROFILE"
      echo "→ Added. Open a new Terminal window to pick it up."
    else
      echo "   To add manually:"
      echo "     echo 'export PATH=\"/usr/local/bin:\$PATH\"' >> ~/.zprofile"
    fi
  fi
fi

echo ""
echo "✅ Setup complete."
[ -d "$APP" ] && { echo "Launching Sandshell…"; open -a "$APP"; }
