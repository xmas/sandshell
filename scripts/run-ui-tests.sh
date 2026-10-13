#!/bin/bash
# Release UI-test runner for Sandshell. Builds (or reuses) a Debug build,
# launches a single dedicated instance of it, drives it through
# tests/ui/*.applescript via osascript, and cleans up after itself.
#
# Usage:
#   scripts/run-ui-tests.sh                 # build + run the full suite
#   scripts/run-ui-tests.sh --skip-build    # reuse the last Debug build
#   scripts/run-ui-tests.sh --app path/to/Sandshell.app
#   scripts/run-ui-tests.sh --force-quit    # quit a running Sandshell first
#   scripts/run-ui-tests.sh --keep-open     # leave the test instance running for inspection
#
# See tests/ui/README.md for how the suite is structured and why.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP=""
BUILD=1
FORCE_QUIT=0
KEEP_OPEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; BUILD=0; shift 2;;
    --skip-build) BUILD=0; shift;;
    --force-quit) FORCE_QUIT=1; shift;;
    --keep-open) KEEP_OPEN=1; shift;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v osascript >/dev/null || { echo "error: osascript not found — this suite only runs on macOS"; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found (needed to parse the status JSON)"; exit 1; }
command -v sbx >/dev/null || { echo "error: sbx CLI not found on PATH"; exit 1; }

# --- Safety gate -------------------------------------------------------------
# These tests target "the one running Sandshell instance" by bundle id, with
# no per-process disambiguation. If the user's own interactive session is
# running, either refuse (default) or quit it first with --force-quit — never
# silently steal input from a live session.
if pgrep -x Sandshell >/dev/null 2>&1; then
  if [[ "$FORCE_QUIT" == "1" ]]; then
    echo "==> Quitting the running Sandshell instance (--force-quit)"
    osascript -e 'tell application "Sandshell" to quit' >/dev/null 2>&1 || true
    for i in $(seq 1 20); do pgrep -x Sandshell >/dev/null 2>&1 || break; sleep 0.5; done
    if pgrep -x Sandshell >/dev/null 2>&1; then
      echo "error: Sandshell is still running; quit it manually and re-run"; exit 1
    fi
  else
    echo "error: Sandshell is already running."
    echo "  This suite drives 'the' Sandshell process with no per-window/per-PID"
    echo "  disambiguation, so it must own the only running instance. Quit"
    echo "  Sandshell yourself, or re-run with --force-quit to have this script"
    echo "  quit it for you."
    exit 1
  fi
fi

# --- Build --------------------------------------------------------------
if [[ "$BUILD" == "1" ]]; then
  command -v xcodegen >/dev/null || { echo "error: xcodegen not found"; exit 1; }
  echo "==> Regenerating project (xcodegen)"
  xcodegen generate >/dev/null
  echo "==> Building Debug for UI tests"
  rm -rf build-uitests
  if ! xcodebuild -project Sandshell.xcodeproj -scheme Sandshell -configuration Debug \
       -derivedDataPath build-uitests -destination 'platform=macOS,arch=arm64' build \
       >/tmp/sandshell-uitest-build.log 2>&1; then
    echo "error: build failed — last lines:"; tail -40 /tmp/sandshell-uitest-build.log; exit 1
  fi
  APP="build-uitests/Build/Products/Debug/Sandshell.app"
fi

[[ -d "$APP" ]] || { echo "error: app not found at '$APP'"; exit 1; }
BIN="$APP/Contents/MacOS/Sandshell"
[[ -x "$BIN" ]] || { echo "error: executable not found at '$BIN'"; exit 1; }
BUNDLE_ID="$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleIdentifier)"
echo "==> Testing $APP ($BUNDLE_ID)"

# --- Isolated test fixtures -----------------------------------------------
TMPWORK="$(mktemp -d /tmp/sandshell-uitest-XXXXXX)"
WINDOW_TITLE="$(basename "$TMPWORK")"
SB_NAME="sandshell-uitest-$$"
SB_CREATED=0
APP_PID=""

cleanup() {
  echo "==> Cleaning up"
  if [[ "$SB_CREATED" == "1" ]]; then
    sbx rm -f "$SB_NAME" >/dev/null 2>&1 || true
  fi
  # Safety net: sweep any throwaway sandbox this suite left behind on a prior
  # crashed run, not just this run's own name.
  sbx ls --json 2>/dev/null | grep -o '"name":"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/' \
    | grep '^sandshell-uitest-' | while read -r n; do sbx rm -f "$n" >/dev/null 2>&1 || true; done
  rm -rf "$TMPWORK"
  if [[ "$KEEP_OPEN" == "0" && -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> Creating a throwaway sandbox ($SB_NAME) for the lifecycle test"
if sbx create shell --name "$SB_NAME" "$TMPWORK" >/tmp/sandshell-uitest-sbxcreate.log 2>&1; then
  SB_CREATED=1
else
  echo "warning: could not create a throwaway sandbox — 03_settings_sandboxes_lifecycle will be skipped"
  tail -10 /tmp/sandshell-uitest-sbxcreate.log
fi

echo "==> Launching a dedicated Sandshell instance"
"$BIN" >/tmp/sandshell-uitest-run.log 2>&1 &
APP_PID=$!
for i in $(seq 1 40); do
  osascript -e "tell application \"System Events\" to return (count of (every application process whose bundle identifier is \"$BUNDLE_ID\")) > 0" 2>/dev/null | grep -q true && break
  sleep 0.5
done

echo "==> Opening the isolated test workspace ($TMPWORK)"
ENCODED_PATH="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$TMPWORK")"
open "sandshell://open?workspace=$ENCODED_PATH"
for i in $(seq 1 20); do
  osascript -e "tell application \"System Events\" to return exists (first window of (first application process whose bundle identifier is \"$BUNDLE_ID\") whose title is \"$WINDOW_TITLE\" or title starts with \"$WINDOW_TITLE — \")" 2>/dev/null | grep -q true && break
  sleep 0.5
done

# --- Run the suite -----------------------------------------------------
TESTS_DIR="tests/ui"
PASS=0
FAIL=0
FAILED_NAMES=()

run_test() {
  local script="$1"; shift
  local name; name="$(basename "$script" .applescript)"
  echo "--- $name ---"
  if out="$(osascript "$script" "$@" 2>&1)"; then
    echo "$out"
    PASS=$((PASS + 1))
  else
    echo "$out"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
  fi
}

run_test "$TESTS_DIR/00_launch_and_status.applescript" "$BUNDLE_ID"
run_test "$TESTS_DIR/01_menu_structure.applescript" "$BUNDLE_ID"
run_test "$TESTS_DIR/02_new_session_via_apple_event.applescript" "$BUNDLE_ID" "$WINDOW_TITLE"
if [[ "$SB_CREATED" == "1" ]]; then
  run_test "$TESTS_DIR/03_settings_sandboxes_lifecycle.applescript" "$BUNDLE_ID" "$WINDOW_TITLE" "$SB_NAME"
fi

echo ""
echo "===================="
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -gt 0 ]] && echo "  Failed: ${FAILED_NAMES[*]}"
echo "===================="
exit $(( FAIL > 0 ? 1 : 0 ))
