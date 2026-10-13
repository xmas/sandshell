#!/bin/bash
cd /Users/xmas/Code/xmas-sandshell || exit 1
DMG=dist/Sandshell-0.2.15.dmg
[ -f "$DMG" ] || { echo "no dmg at $DMG"; exit 1; }
ls -la "$DMG"
MNT=$(hdiutil attach -nobrowse -readonly "$DMG" 2>&1 | grep -o '/Volumes/.*' | tail -1)
echo "mounted at: $MNT"
ls -la "$MNT" 2>&1
echo "--- .background:"; ls -la "$MNT/.background" 2>&1
echo "--- app version:"; /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MNT/Sandshell.app/Contents/Info.plist" 2>&1
hdiutil detach "$MNT" -quiet 2>&1
