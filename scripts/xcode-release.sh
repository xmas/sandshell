#!/bin/bash
# Xcode's Publish scheme runs this, so a release can start from a sandbox:
# scripts/xcode-sandbox.py release <version> leaves the version in
# .release-request and builds the scheme. Building it with no request does
# nothing.
#
# The release runs on the Mac, with the Mac's gh login, and asks there first.
# It runs apart from Xcode's build: release.sh regenerates the project Xcode has
# open, and Xcode's build settings mustn't reach its own xcodebuild. Progress is
# in release.log, which ends with "RELEASE FINISHED" and the exit code.
#
# The dialog is there so nothing publishes by accident. It isn't a wall: a
# sandbox with this folder mounted and Xcode loaded can change this script.
set -u
root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
log="$root/release.log"

if [ "${1:-}" = "--run" ]; then
  version="$2"
  answer="$(osascript -e "display dialog \"Publish Sandshell $version?\" & return & return & \"This builds the release and publishes it to Homebrew, using your GitHub login, then pushes main.\" with title \"Sandshell Release\" buttons {\"Cancel\", \"Publish\"} default button \"Cancel\" with icon caution giving up after 900" 2>&1)"
  case "$answer" in
    *"button returned:Publish"*"gave up:false"*) ;;
    *) echo "RELEASE FINISHED 1: not confirmed on the Mac ($answer)"; exit 1 ;;
  esac
  cd "$root" || exit 1
  scripts/release.sh "$version"
  code=$?
  echo "RELEASE FINISHED $code"
  exit "$code"
fi

request="$root/.release-request"
[ -f "$request" ] || { echo "No release was asked for."; exit 0; }
version="$(tr -d '[:space:]' < "$request")"
rm -f "$request"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: not a version: $version"
  exit 1
fi

: > "$log"
nohup /usr/bin/env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" LANG="${LANG:-en_US.UTF-8}" \
  /bin/zsh -lc 'exec "$0" --run "$1"' "$root/scripts/xcode-release.sh" "$version" >> "$log" 2>&1 < /dev/null &
disown
echo "Release $version started: confirm it on the Mac. Progress: release.log"
