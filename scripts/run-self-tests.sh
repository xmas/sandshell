#!/usr/bin/env bash
# Run Sandshell's DEBUG self-tests (App/SelfTest.swift) end to end, each on a
# fixture this script makes or resets first — so a run never depends on what
# an earlier one left behind. Prints a summary; exits non-zero on any failure.
#
#   scripts/run-self-tests.sh                 everything (≈30–60 min; some scenarios use
#                                             the signed-in Claude account for tiny turns)
#   scripts/run-self-tests.sh --quick         no agent turns, no sandboxes created from scratch
#   scripts/run-self-tests.sh --only a,b      just these scenarios
#   scripts/run-self-tests.sh --skip-build    reuse the last dev build
#
# Builds a separate dev bundle (com.xmas.sandshell.dev, build-dev/) so your own
# Sandshell and its settings are untouched. Fixtures live under
# $SANDSHELL_SELFTEST_ROOT (default /tmp/sandshell-selftests); results under
# <root>/results/<timestamp>/<scenario>/ (selftest.log, run.log, snapshots).
# Two runs at once (e.g. from separate worktrees) need their own root and
# bundle id: SANDSHELL_SELFTEST_ROOT=/tmp/st-a SANDSHELL_SELFTEST_BUNDLE_ID=com.xmas.sandshell.dev-a
# Never puts up a dialog (Diagnostics/AutomatedRun.swift).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="${SANDSHELL_SELFTEST_ROOT:-/tmp/sandshell-selftests}"
BUNDLE_ID="${SANDSHELL_SELFTEST_BUNDLE_ID:-com.xmas.sandshell.dev}"
APP="$ROOT/build-dev/Build/Products/Debug/Sandshell.app/Contents/MacOS/Sandshell"
HELP="$ROOT/scripts/selftest_fixtures.py"
QUICK=0 SKIP_BUILD=0 ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --only) [[ $# -ge 2 ]] || { echo "--only needs a list" >&2; exit 2; }; ONLY=",$2,"; shift ;;
    -h|--help) sed -n 2,17p "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

command -v sbx >/dev/null || { echo "sbx isn't on PATH" >&2; exit 2; }
mkdir -p "$FIX"
RESULTS="$FIX/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS"

if [[ $SKIP_BUILD == 0 ]]; then
  echo "==> Building the dev app"
  BUILD_LOG="$RESULTS/build.log"
  if ! (cd "$ROOT" && xcodegen generate >/dev/null && xcodebuild -project Sandshell.xcodeproj -scheme Sandshell \
     -configuration Debug -derivedDataPath build-dev -destination 'platform=macOS,arch=arm64' \
     PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build > "$BUILD_LOG" 2>&1); then
    grep -E " error:" "$BUILD_LOG" | head -20
    echo "build failed (log: $BUILD_LOG)" >&2; exit 1
  fi
  echo "   built"
fi
[[ -x "$APP" ]] || { echo "no dev build at $APP" >&2; exit 2; }

fixture() { python3 "$HELP" "$FIX" "$@"; }
KITDIRS=()
while IFS= read -r line; do KITDIRS+=("$line"); done < <(fixture kitdirs)

# Run the app on a workspace. bootstrap: just open and quit (so the app writes
# its config.json for a fixture's config edits).
LIMIT=600   # seconds a scenario may take (set per kind in run)
launch() {   # launch <scenario> <fixture> <outdir> [extra args…]
  local scenario="$1" ws="$FIX/$2" out="$3"; shift 3
  mkdir -p "$out"; rm -f "$out/selftest.log"
  perl -e "alarm $LIMIT; exec @ARGV" "$APP" -SandshellSelfTest "$scenario" -SandshellSelfTestOut "$out" "$@" \
    -openWindowRoots "(\"$ws\")" > "$out/run.log" 2>&1
}

PASSED=() FAILED=()
run() {   # run <scenario> <fixture> <kind: quick|account|fresh> [extra args…]
  local scenario="$1" fx="$2" kind="$3"; shift 3
  [[ -n "$ONLY" && "$ONLY" != *",$scenario,"* ]] && return
  [[ $QUICK == 1 && "$kind" != quick ]] && return
  flush_pending
  local out="$RESULTS/$scenario"
  case "$kind" in quick) LIMIT=600 ;; account) LIMIT=1500 ;; *) LIMIT=2400 ;; esac
  printf '%-16s %-10s ' "$scenario" "$fx"
  local started=$SECONDS
  launch "$scenario" "$fx" "$out" "$@"
  local log="$out/selftest.log"
  local pass fail
  pass=$(grep -c '^PASS ' "$log" 2>/dev/null || true); fail=$(grep -c '^FAIL ' "$log" 2>/dev/null || true)
  if [[ ! -f "$log" ]]; then fail=1; echo "no result (crashed or timed out — see $out/run.log)"
  elif ! grep -q 'ALL PASSED' "$log"; then fail=$(( fail > 0 ? fail : 1 )); fi
  if [[ "$fail" == 0 ]]; then
    PASSED+=("$scenario"); printf '✓ %3s checks  %4ss\n' "$pass" $((SECONDS - started))
  else
    FAILED+=("$scenario"); printf '✗ %s of %s failed  %ss\n' "$fail" $((pass + fail)) $((SECONDS - started))
    grep -E '^FAIL |^need |unexpected' "$log" 2>/dev/null | sed 's/^/      /' | head -8
  fi
}

# Fixture steps wait until a scenario that's actually run needs them (so
# --only / --quick don't bootstrap or delete sandboxes for nothing).
PENDING=()
prepare()   { PENDING+=("prepare:$1"); }
configure() { PENDING+=("configure:$1"); }
rmboxes()   { PENDING+=("rm-sandboxes:$1"); }
flush_pending() {
  local step fx
  for step in "${PENDING[@]+"${PENDING[@]}"}"; do
    fx="${step#*:}"
    case "$step" in
      prepare:*) fixture prepare "$fx" >/dev/null ;;
      configure:*)
        [[ -f "$FIX/$fx/.sandshell/config.json" ]] || { LIMIT=300; launch bootstrap "$fx" "$RESULTS/.bootstrap-$fx"; }
        fixture config "$fx" ;;
      rm-sandboxes:*) fixture rm-sandboxes "$fx" >/dev/null ;;
    esac
  done
  PENDING=()
}

echo "==> Fixtures in $FIX, results in $RESULTS"
echo ""

# Offscreen views, no agent.
prepare chat
run tables         chat   quick
run tool-groups    chat   quick
run links          chat   quick
run open-quickly   chat   quick
run sea            chat   quick
run alerts         chat   quick

# Files, panes, the title strip (shell sessions in existing sandboxes).
prepare files
run files          files  quick
run files-relaunch files  quick
prepare files
run commits        files  quick
prepare files
run sandbox-access files  quick
run panes          files  quick
run pane-buttons   files  quick
run files-alone    files  quick
run two-windows    files  quick
prepare files
run mac            files  quick
prepare title-strip-workspace   # a long name: the folder chip test measures it
run title-strip    title-strip-workspace quick
prepare title-strip-workspace
run paste          title-strip-workspace quick

# Kits and agents (sandboxes rebuilt with test kits).
prepare kits;      configure kits
run kits           kits   quick "-SandshellSelfTestKits" "(\"${KITDIRS[0]}\",\"${KITDIRS[1]}\",\"${KITDIRS[2]}\",\"${KITDIRS[3]}\",\"${KITDIRS[4]}\")"
prepare kitagents; configure kitagents
run kit-agents     kitagents quick
prepare broken;    configure broken; rmboxes broken
run launch-failure broken quick
prepare agents
run agents         agents quick "-SandshellSelfTestKit" "$FIX/kitdirs/agent"
prepare search
run search         search quick

# Real agent turns (the signed-in account, a few tiny turns each).
for s in chat fork follow reconnect chat-model background warm queue question subagents details; do
  prepare chat
  run "$s" chat account
done
run codex-chat     kits   account

# Sandboxes made from scratch.
prepare fresh; rmboxes fresh
run building       fresh  fresh
prepare fresh; rmboxes fresh
run kit-extras     fresh  fresh   # also Undo / Stop / MCP (extras) with the kit
prepare clone; rmboxes clone
run clone          clone  fresh   # sbx create --clone: the agent's commits come back by git

echo ""
echo "${#PASSED[@]} passed, ${#FAILED[@]} failed${FAILED[*]:+: ${FAILED[*]}}"
echo "results: $RESULTS"
[[ ${#FAILED[@]} == 0 ]]
