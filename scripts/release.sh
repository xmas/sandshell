#!/bin/bash
# Cut a Sandshell release: bump version → build Release → make DMG → upload to
# the docker.com-shared Drive releases folder (filename = version tag, which is
# what the in-app updater compares against).
#
# Usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.1.1
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then echo "usage: scripts/release.sh <version>  (e.g. 0.1.1)"; exit 1; fi
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "error: version must be numeric dotted, e.g. 0.1.1"; exit 1
fi

FOLDER_ID="1TDO_iVfaobA3tYiF8JM_1NA_DBpEANjl"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null || { echo "error: xcodegen not found"; exit 1; }
command -v gws >/dev/null || { echo "error: gws (Google Workspace CLI) not found"; exit 1; }

# Pull the id out of a gws JSON response.
gws_id() { grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/'; }

echo "==> Setting MARKETING_VERSION to $VERSION"
/usr/bin/sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:).*/\1 \"$VERSION\"/" project.yml
xcodegen generate >/dev/null

echo "==> Building Release (this can take a minute)…"
rm -rf build-release
# Full log in the project (git-ignored build dir) so it's readable from the sandbox too.
mkdir -p build
BUILD_LOG="build/release-build.log"
if ! xcodebuild -project Sandshell.xcodeproj -scheme Sandshell -configuration Release \
     -derivedDataPath build-release -destination 'platform=macOS,arch=arm64' build \
     >"$BUILD_LOG" 2>&1; then
  echo "error: build failed (full log: $BUILD_LOG) — compiler errors:"
  grep -E '(error|warning: .*will be an error):' "$BUILD_LOG" | sort -u | head -40 || tail -25 "$BUILD_LOG"
  exit 1
fi
APP="build-release/Build/Products/Release/Sandshell.app"

echo "==> Building DMG"
DMG="$(scripts/make-dmg.sh "$APP" "$VERSION" dist | tail -1)"
[[ -f "$DMG" ]] || { echo "error: DMG was not created at '$DMG'"; exit 1; }
echo "    $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"

# Project-root pointer to the newest DMG (relative, so it works from either
# side of the sandbox mount). Git-ignored.
ln -sfn "$DMG" Sandshell-latest.dmg
echo "    Sandshell-latest.dmg -> $DMG"

echo "==> Uploading Sandshell-$VERSION.dmg to Drive"
# Replace an existing same-named release so re-runs don't pile up duplicates.
EXISTING="$(gws drive files list \
  --params "{\"q\": \"'$FOLDER_ID' in parents and name='Sandshell-$VERSION.dmg' and trashed=false\", \"fields\": \"files(id)\"}" \
  --format json 2>/dev/null | gws_id || true)"
if [[ -n "${EXISTING:-}" ]]; then
  gws drive files delete --params "{\"fileId\": \"$EXISTING\"}" >/dev/null 2>&1 || true
fi
ID="$(gws drive +upload "$DMG" --parent "$FOLDER_ID" --name "Sandshell-$VERSION.dmg" --format json 2>/dev/null | gws_id)"

echo ""
echo "✅ Released Sandshell $VERSION"
echo "   DMG:    https://drive.google.com/file/d/$ID/view"
echo "   Folder: https://drive.google.com/drive/folders/$FOLDER_ID"
echo ""
echo "Reminder: commit the project.yml version bump when ready."
