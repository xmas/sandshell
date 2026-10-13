#!/bin/bash
cd /Users/xmas/Code/xmas-sandshell || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
xcodegen generate 2>&1 | tail -3
xcodebuild -project Sandshell.xcodeproj -scheme Sandshell -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E 'error:|warning: .*KitStartup|warning: .*TerminalStack|BUILD (SUCCEEDED|FAILED)|\*\* '
rc=${PIPESTATUS[0]}
echo "build exit: $rc"
exit $rc
