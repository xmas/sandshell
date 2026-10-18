#!/bin/bash
# Build a styled "drag to Applications" DMG for Sandshell.
# Usage: scripts/make-dmg.sh <path-to-Sandshell.app> <version> [output-dir]
set -euo pipefail

APP="${1:?path to Sandshell.app}"
VERSION="${2:?version}"
OUTDIR="${3:-dist}"
VOL="Sandshell"
DMG="$OUTDIR/Sandshell-$VERSION.dmg"

mkdir -p "$OUTDIR"
rm -f "$DMG"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_NAME="Sandshell Setup.command"

STAGE="$(mktemp -d)"
RW="$(mktemp -u).dmg"
trap 'rm -rf "$STAGE" "$RW"' EXIT

# 1. Stage the app, an /Applications symlink (drag target), a Terminal.app
#    symlink (shown in the window), the setup script (kept but offscreen), and
#    a Read Me.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
ln -s /System/Applications/Utilities/Terminal.app "$STAGE/Terminal.app"
cp "$SCRIPT_DIR/sandshell-setup.command" "$STAGE/$SETUP_NAME"
chmod +x "$STAGE/$SETUP_NAME"
cp "$SCRIPT_DIR/dmg-readme.txt" "$STAGE/Read Me First.txt"
# Versioned, ever-growing release notes (canonical copy lives in the repo root).
cp "$SCRIPT_DIR/../CHANGELOG.md" "$STAGE/Release Notes.txt"

# Custom window background (hidden .background folder), drawn once by
# make-dmg-background.py: rerun it (it needs Pillow) after changing the design.
mkdir -p "$STAGE/.background"
cp "$SCRIPT_DIR/dmg-background.png" "$STAGE/.background/background.png"

# 2. Create a read/write DMG sized to the content (+ slack for the layout).
SIZE_KB=$(du -sk "$STAGE" | cut -f1)
SIZE_MB=$(( SIZE_KB / 1024 + 60 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE_MB}m" "$RW" >/dev/null

# 3. Mount it and lay out the window. Finder scripting is flaky when run
#    non-interactively, so wait for the volume, activate Finder, set the
#    background first, settle, and verify the .DS_Store grew — retry if not.
MOUNT_DIR="/Volumes/$VOL"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')
for _ in $(seq 1 20); do [ -d "$MOUNT_DIR" ] && break; sleep 0.5; done
sleep 2

layout() {
  osascript <<APPLESCRIPT
tell application "Finder"
  activate
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 600x480-pt content area (+titlebar); matches the 2x background image.
    set the bounds of container window to {180, 110, 780, 618}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set text size of theViewOptions to 13
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "Sandshell.app" of container window to {155, 190}
    set position of item "Applications" of container window to {445, 190}
    set position of item "Read Me First.txt" of container window to {155, 370}
    set position of item "Release Notes.txt" of container window to {300, 370}
    set position of item "Terminal.app" of container window to {445, 370}
    try
      set position of item ".background" of container window to {1100, 1000}
    end try
    try
      set position of item "$SETUP_NAME" of container window to {1100, 1100}
    end try
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
}

# Try, then retry once if the layout didn't take (a too-small .DS_Store means
# the background/positions weren't saved).
layout || { sleep 2; layout || true; }
sync
sleep 1
DS_SIZE=$(stat -f%z "$MOUNT_DIR/.DS_Store" 2>/dev/null || echo 0)
if [ "$DS_SIZE" -lt 4000 ]; then
  echo "warning: DMG layout may not have applied (.DS_Store ${DS_SIZE}B); retrying" >&2
  layout || true; sync; sleep 1
fi

# 4. Hide/clean the volume's dot-files so they don't clutter the window, then
#    detach and convert to a compressed, read-only DMG.
rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes" >/dev/null 2>&1 || true
SetFile -a V "$MOUNT_DIR/.background" >/dev/null 2>&1 || chflags hidden "$MOUNT_DIR/.background" >/dev/null 2>&1 || true
sync

hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
sleep 1
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "$DMG"
