#!/bin/bash
pkill -9 -f 'xmas-sandshell/build/Build/Products/Debug/Sandshell.app/Contents/MacOS/Sandshell' 2>/dev/null
sleep 1
open -n /Users/xmas/Code/xmas-sandshell/build/Build/Products/Debug/Sandshell.app
sleep 1
pgrep -fl 'Debug/Sandshell.app/Contents/MacOS/Sandshell'
