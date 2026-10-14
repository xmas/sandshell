#!/bin/bash
# Release UI-test runner for Sandshell. Builds (or reuses) a Debug build with
# its own bundle id, launches it headless (no focus, invisible windows) beside
# any Sandshell you have open, drives it through tests/ui/*.applescript via
# osascript, and cleans up after itself.
#
# Usage:
#   scripts/run-ui-tests.sh                 # build + run the full suite
#   scripts/run-ui-tests.sh --skip-build    # reuse the last Debug build
#   scripts/run-ui-tests.sh --app path/to/Sandshell.app
#   scripts/run-ui-tests.sh --force-quit    # kill a leftover test instance first
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

# --- Build --------------------------------------------------------------
# The suite's instance gets its own bundle id: separate UserDefaults (no
# restored windows, no saved layouts), and System Events / Apple Events can
# address it without touching the user's own Sandshell.
UITEST_BUNDLE_ID="com.xmas.sandshell.uitest"
if [[ "$BUILD" == "1" ]]; then
  command -v xcodegen >/dev/null || { echo "error: xcodegen not found"; exit 1; }
  echo "==> Regenerating project (xcodegen)"
  xcodegen generate >/dev/null
  echo "==> Building Debug for UI tests"
  mkdir -p build-uitests
  # Reuse an already-resolved libghostty package if there is one (APFS clone).
  for d in build-dev build; do
    if [[ ! -d build-uitests/SourcePackages && -d "$d/SourcePackages" ]]; then cp -cR "$d/SourcePackages" build-uitests/; fi
  done
  if ! xcodebuild -project Sandshell.xcodeproj -scheme Sandshell -configuration Debug \
       -derivedDataPath build-uitests PRODUCT_BUNDLE_IDENTIFIER="$UITEST_BUNDLE_ID" \
       SANDSHELL_APP_NAME=SandshellUITest \
       -destination 'platform=macOS,arch=arm64' build \
       >/tmp/sandshell-uitest-build.log 2>&1; then
    echo "error: build failed — last lines:"; tail -40 /tmp/sandshell-uitest-build.log; exit 1
  fi
  APP="build-uitests/Build/Products/Debug/Sandshell.app"
fi

[[ -n "$APP" ]] || APP="build-uitests/Build/Products/Debug/Sandshell.app"
[[ -d "$APP" ]] || { echo "error: app not found at '$APP'"; exit 1; }
# System Events re-resolves a process by its executable name, so a test
# instance whose executable is also "Sandshell" can be confused with yours —
# AX actions would land in your app. Run a copy whose executable is renamed.
TEST_APP="$ROOT/build-uitests/SandshellUITest.app"
rm -rf "$TEST_APP"
ditto "$APP" "$TEST_APP"
mv "$TEST_APP/Contents/MacOS/Sandshell" "$TEST_APP/Contents/MacOS/SandshellUITest"
plutil -replace CFBundleExecutable -string SandshellUITest "$TEST_APP/Contents/Info.plist"
codesign --force --deep --sign - --preserve-metadata=entitlements,flags "$TEST_APP" >/dev/null 2>&1 \
  || { echo "error: could not re-sign $TEST_APP"; exit 1; }
APP="$TEST_APP"
BIN="$APP/Contents/MacOS/SandshellUITest"
BUNDLE_ID="$(defaults read "$APP/Contents/Info" CFBundleIdentifier)"
echo "==> Testing $APP ($BUNDLE_ID)"

# --- Safety gate -------------------------------------------------------------
# Apple Events and System Events address the instance by bundle id, so another
# process with this bundle id must not be running. The user's own Sandshell
# (com.xmas.sandshell) is a different bundle id and is left alone.
if [[ "$BUNDLE_ID" == "com.xmas.sandshell" ]]; then
  echo "error: '$APP' has the release bundle id; the suite would collide with your own"
  echo "  Sandshell (and its saved windows). Build with the runner (it uses $UITEST_BUNDLE_ID)."
  exit 1
fi
if pgrep -f "$BIN" >/dev/null 2>&1; then
  if [[ "$FORCE_QUIT" == "1" ]]; then
    echo "==> Killing a leftover test instance (--force-quit)"
    pkill -f "$BIN" || true
    sleep 1
  else
    echo "error: a test instance ($BIN) is already running — re-run with --force-quit"; exit 1
  fi
fi

# --- Isolated test fixtures -----------------------------------------------
TMPWORK="$(mktemp -d /tmp/sandshell-uitest-XXXXXX)"
# The lifecycle test's sandbox gets its own folder so the test window never
# adopts it as its workspace sandbox.
SBWORK="$(mktemp -d /tmp/sandshell-uitest-sb-XXXXXX)"
# Requests/responses between the tests and the app (see tests/ui/lib/Helpers).
export SANDSHELL_UITEST_BRIDGE="$(mktemp -d /tmp/sandshell-uitest-bridge-XXXXXX)"
WINDOW_TITLE="$(basename "$TMPWORK")"
SB_NAME="sandshell-uitest-$$"
SB_CREATED=0
APP_PID=""

cleanup() {
  echo "==> Cleaning up"
  if [[ "$KEEP_OPEN" == "0" && -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
  # Sweep every throwaway sandbox: the lifecycle test's, the test workspace's
  # (named after the temp folder), and any left by a prior crashed run.
  sbx ls --json 2>/dev/null | python3 -c 'import json,sys
for s in json.load(sys.stdin):
    print(s["name"])' 2>/dev/null \
    | grep '^sandshell-uitest-' | while read -r n; do sbx rm -f "$n" >/dev/null 2>&1 || true; done
  rm -rf "$TMPWORK" "$SBWORK" "$SANDSHELL_UITEST_BRIDGE"
  if [[ "$KEEP_OPEN" == "0" ]]; then
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    # Keep sandshell:// URLs going to the user's installed app.
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$ROOT/build-uitests/Build/Products/Debug/Sandshell.app" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

# A plain-shell workspace (fast to create, never starts an agent with your
# account) that skips the mounts sheet.
mkdir -p "$TMPWORK/.sandshell"
echo '{"configured": true, "primaryAgent": "shell", "policy": {"selections": []}}' > "$TMPWORK/.sandshell/config.json"

echo "==> Creating a throwaway sandbox ($SB_NAME) for the lifecycle test"
if sbx create shell --name "$SB_NAME" "$SBWORK" >/tmp/sandshell-uitest-sbxcreate.log 2>&1; then
  SB_CREATED=1
else
  echo "warning: could not create a throwaway sandbox — 04_settings_sandboxes_lifecycle will be skipped"
  tail -10 /tmp/sandshell-uitest-sbxcreate.log
fi

# Headless: the instance never activates, and its windows (sheets included)
# stay transparent, click-through and behind other apps — the suite drives it
# with Apple Events and AX actions only, so it can run while you work.
echo "==> Launching a headless test instance"
"$BIN" -SandshellUITestHeadless YES -SandshellUITestBridge "$SANDSHELL_UITEST_BRIDGE" \
  -ApplePersistenceIgnoreState YES >/tmp/sandshell-uitest-run.log 2>&1 &
APP_PID=$!
for i in $(seq 1 40); do
  osascript -e "tell application \"System Events\" to return (count of (every application process whose bundle identifier is \"$BUNDLE_ID\")) > 0" 2>/dev/null | grep -q true && break
  sleep 0.5
done

# Through the bridge: `open sandshell://…` would go to whichever app
# LaunchServices picks (usually the installed one).
echo "==> Opening the test workspace via sandshell:// ($TMPWORK)"
ENCODED_PATH="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$TMPWORK")"
printf %s "open sandshell://open?workspace=$ENCODED_PATH" > "$SANDSHELL_UITEST_BRIDGE/request"
for i in $(seq 1 100); do [[ -f "$SANDSHELL_UITEST_BRIDGE/response" ]] && break; sleep 0.1; done

# --- Run the suite -----------------------------------------------------
TESTS_DIR="tests/ui"
# `load script` only takes compiled scripts, so compile the shared helpers.
osacompile -o "$TESTS_DIR/lib/Helpers.scpt" "$TESTS_DIR/lib/Helpers.applescript" || { echo "error: tests/ui/lib/Helpers.applescript doesn't compile"; exit 1; }
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

run_test "$TESTS_DIR/00_launch_and_status.applescript" "$BUNDLE_ID" "$WINDOW_TITLE"
run_test "$TESTS_DIR/02_new_session_while_building.applescript" "$BUNDLE_ID" "$WINDOW_TITLE"
run_test "$TESTS_DIR/01_menu_structure.applescript" "$BUNDLE_ID"
run_test "$TESTS_DIR/03_flat_session_order.applescript" "$BUNDLE_ID" "$WINDOW_TITLE"
if [[ "$SB_CREATED" == "1" ]]; then
  run_test "$TESTS_DIR/04_settings_sandboxes_lifecycle.applescript" "$BUNDLE_ID" "$WINDOW_TITLE" "$SB_NAME"
fi

echo ""
echo "===================="
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -gt 0 ]] && echo "  Failed: ${FAILED_NAMES[*]}"
echo "===================="
exit $(( FAIL > 0 ? 1 : 0 ))
