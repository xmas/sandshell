#!/usr/bin/env bash
# Run the Swift Testing unit tests (tests/SandshellTests), hosted in a Debug
# build of the app — which opens no windows and touches no sandboxes when it's
# hosting tests (AppDelegate.isHostingTests).
#
#   scripts/run-unit-tests.sh                 build + run every test
#   scripts/run-unit-tests.sh FormatTests     only these suites / tests (-only-testing)
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
only=()
for t in "$@"; do only+=("-only-testing:SandshellTests/$t"); done
set -o pipefail
xcodebuild test -project Sandshell.xcodeproj -scheme Sandshell -configuration Debug \
  -derivedDataPath build-tests -destination 'platform=macOS,arch=arm64' \
  ${only[@]+"${only[@]}"} 2>&1 | tee build-tests.log | \
  grep -E '^(Test |􀟈|􁁛|􀢄|✔|✘|◇)|Test run with|Suite .* (passed|failed)|error:|\*\* TEST' || true
grep -q '\*\* TEST SUCCEEDED \*\*' build-tests.log
