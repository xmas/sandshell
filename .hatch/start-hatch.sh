#!/bin/bash
# Starts hatch-mcp in HTTP mode on port 31337.
# Run this on your Mac before (or after) launching the sbx sandbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/hatch-mcp"

if [ ! -f "$BIN" ]; then
  echo "hatch-mcp binary not found at $BIN" >&2
  echo "Installing hatch-mcp is outside the kit — see hatch-kit/README.md" >&2
  echo "in docker/xmas-kits (launchd is the recommended way to run it)." >&2
  exit 1
fi

echo "Starting hatch-mcp on port 31337..."
exec "$BIN" --transport http --host 127.0.0.1 --port 31337 "$@"
