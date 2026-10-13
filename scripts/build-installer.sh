#!/bin/bash
# Compile the first-install assistant AppleScript into a runnable .app.
# Output: dist/Sandshell Installer.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p dist
OUT="dist/Sandshell Installer.app"
rm -rf "$OUT"
osacompile -o "$OUT" scripts/sandshell-installer.applescript
echo "Built: $OUT"
