#!/bin/bash
# Cut a Sandshell release and publish it through the Homebrew tap.
#
#   bump MARKETING_VERSION → Release build → DMG → sha256 →
#   GitHub release `sandshell-v<version>` on xmas/homebrew-xmas (public; the
#   app repo is private) → update + push Casks/sandshell.rb in the tap →
#   commit the bump here, tag v<version>, push → publish kits/ to
#   xmas/sandshell-kits (scripts/publish-kits.sh).
#
# Usage: scripts/release.sh [--dry-run] <version>      e.g. scripts/release.sh 0.2.20
#
# --dry-run runs every preflight check (failures become warnings), does the
# real Release build + DMG + sha256, and prints the cask diff and the exact
# publish commands — but never edits project.yml, the tap clone, or anything
# remote.
#
# Env: SANDSHELL_TAP_DIR  local clone of xmas/homebrew-xmas (default ../homebrew-xmas)
set -euo pipefail

DRY_RUN=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown flag $arg" >&2; exit 1 ;;
    *) VERSION="$arg" ;;
  esac
done
if [[ -z "$VERSION" ]]; then echo "usage: scripts/release.sh [--dry-run] <version>  (e.g. 0.2.20)"; exit 1; fi
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "error: version must be numeric dotted, e.g. 0.2.20"; exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAP_REPO="xmas/homebrew-xmas"
TAP_DIR="${SANDSHELL_TAP_DIR:-$ROOT/../homebrew-xmas}"
TAP_DIR="$(cd "$TAP_DIR" 2>/dev/null && pwd || echo "$TAP_DIR")"
CASK_REL="Casks/sandshell.rb"
CASK="$TAP_DIR/$CASK_REL"
TAG="sandshell-v$VERSION"            # tap release tag (namespaced: the tap also hosts other apps)
APP_TAG="v$VERSION"                  # tag in this repo
# Uncommitted changes allowed in this repo at release time (committed with the bump).
ALLOWED_DIRTY=(project.yml CHANGELOG.md)

WORK="$(mktemp -d)"
YML_BACKUP=""
cleanup() {
  # A real run that fails before committing the bump puts project.yml back.
  if [[ -n "$YML_BACKUP" && -f "$YML_BACKUP" ]]; then
    cp "$YML_BACKUP" project.yml
    xcodegen generate >/dev/null 2>&1 || true
    echo "    (restored project.yml)" >&2
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Print a command; execute it unless --dry-run.
run() {
  printf '  +'; printf ' %q' "$@"; printf '\n'
  [[ $DRY_RUN == 1 ]] || "$@"
}

# ── Preflight ────────────────────────────────────────────────────────────────
echo "==> Preflight$([[ $DRY_RUN == 1 ]] && echo " (dry run: failures are warnings)")"
PROBLEMS=()
problem() { PROBLEMS+=("$1"); echo "    ✗ $1"; }
ok()      { echo "    ✓ $1"; }

for tool in xcodegen xcodebuild gh git shasum hdiutil; do
  command -v "$tool" >/dev/null || problem "$tool not found on PATH"
done

# make-dmg.sh draws the DMG background with Pillow; fail now, not after the build.
HAVE_PIL=0
for cand in /usr/bin/python3 python3 /opt/homebrew/bin/python3; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import PIL' >/dev/null 2>&1; then HAVE_PIL=1; break; fi
done
[[ $HAVE_PIL == 1 ]] && ok "python3 with Pillow" || problem "no python3 with Pillow (needed by make-dmg.sh): /usr/bin/python3 -m pip install --user pillow"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == main ]] && ok "on main" || problem "sandshell is on '$BRANCH', not main"

DIRTY="$(git status --porcelain --untracked-files=all | while IFS= read -r line; do
  path="${line:3}"; keep=1
  for a in "${ALLOWED_DIRTY[@]}"; do [[ "$path" == "$a" ]] && keep=0; done
  if [[ $keep == 1 ]]; then echo "$path"; fi
done)"
if [[ -z "$DIRTY" ]]; then ok "working tree clean (allowing: ${ALLOWED_DIRTY[*]})"
else problem "uncommitted changes outside ${ALLOWED_DIRTY[*]}:"; echo "$DIRTY" | sed 's/^/        /'; fi

if git rev-parse -q --verify "refs/tags/$APP_TAG" >/dev/null; then problem "tag $APP_TAG already exists locally"
else ok "tag $APP_TAG is free locally"; fi

if gh auth status >/dev/null 2>&1; then
  ok "gh authenticated"
  if gh release view "$TAG" -R "$TAP_REPO" >/dev/null 2>&1; then problem "release $TAG already exists on $TAP_REPO"
  else ok "release $TAG is free on $TAP_REPO"; fi
else
  problem "gh is not authenticated (gh auth login)"
fi

if [[ ! -d "$TAP_DIR/.git" ]]; then
  problem "tap clone not found at $TAP_DIR (gh repo clone $TAP_REPO \"$TAP_DIR\")"
else
  TAP_BRANCH="$(git -C "$TAP_DIR" rev-parse --abbrev-ref HEAD)"
  [[ "$TAP_BRANCH" == main ]] && ok "tap clone on main" || problem "tap clone is on '$TAP_BRANCH', not main"
  [[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] && ok "tap clone clean" || problem "tap clone has uncommitted changes"
  if git -C "$TAP_DIR" fetch -q origin main 2>/dev/null; then
    if [[ "$(git -C "$TAP_DIR" rev-parse HEAD)" == "$(git -C "$TAP_DIR" rev-parse origin/main)" ]]; then ok "tap clone up to date with origin/main"
    else problem "tap clone HEAD differs from origin/main (pull/merge first)"; fi
  else
    problem "could not fetch the tap's origin"
  fi
  if [[ ! -f "$CASK" ]]; then problem "$CASK_REL missing in tap clone"
  elif ! grep -q 'sandshell-v#{version}/Sandshell-#{version}.dmg' "$CASK"; then
    problem "$CASK_REL is not the native-app cask (expected url …/sandshell-v#{version}/Sandshell-#{version}.dmg)"
  else
    ok "$CASK_REL is the native-app cask"
    CASK_VERSION="$(sed -nE 's/^  version "([^"]*)".*/\1/p' "$CASK")"
    [[ "$CASK_VERSION" != "$VERSION" ]] || problem "cask is already at $VERSION"
  fi
fi

CUR_VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"]*)"?.*/\1/p' project.yml | head -1)"
echo "    · MARKETING_VERSION now $CUR_VERSION → $VERSION"

if (( ${#PROBLEMS[@]} )); then
  if [[ $DRY_RUN == 1 ]]; then echo "    ! ${#PROBLEMS[@]} preflight problem(s) — a real run would stop here"
  else echo "error: ${#PROBLEMS[@]} preflight problem(s); fix them and re-run (or try --dry-run)" >&2; exit 1; fi
fi

# ── Version bump ─────────────────────────────────────────────────────────────
if [[ $DRY_RUN == 1 ]]; then
  echo "==> (dry run) leaving project.yml alone; building with MARKETING_VERSION=$VERSION override"
else
  echo "==> Setting MARKETING_VERSION to $VERSION"
  YML_BACKUP="$WORK/project.yml"; cp project.yml "$YML_BACKUP"
  /usr/bin/sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:).*/\1 \"$VERSION\"/" project.yml
fi
xcodegen generate >/dev/null

# ── Build ────────────────────────────────────────────────────────────────────
echo "==> Building Release (this can take a minute)…"
rm -rf build-release
# Full log in the project (git-ignored build dir) so it's readable from the sandbox too.
mkdir -p build
BUILD_LOG="build/release-build.log"
if ! xcodebuild -project Sandshell.xcodeproj -scheme Sandshell -configuration Release \
     -derivedDataPath build-release -destination 'platform=macOS,arch=arm64' \
     MARKETING_VERSION="$VERSION" build >"$BUILD_LOG" 2>&1; then
  echo "error: build failed (full log: $BUILD_LOG) — compiler errors:"
  grep -E '(error|warning: .*will be an error):' "$BUILD_LOG" | sort -u | head -40 || tail -25 "$BUILD_LOG"
  exit 1
fi
APP="build-release/Build/Products/Release/Sandshell.app"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" ]] || { echo "error: built app reports $BUILT_VERSION, expected $VERSION"; exit 1; }
[[ -x "$APP/Contents/Resources/sandshell" ]] || { echo "error: sandshell CLI missing from the bundle (cask binary stanza needs it)"; exit 1; }
echo "    $APP ($BUILT_VERSION)"

# ── DMG + checksum ───────────────────────────────────────────────────────────
echo "==> Building DMG"
DMG="$(scripts/make-dmg.sh "$APP" "$VERSION" dist | tail -1)"
[[ -f "$DMG" ]] || { echo "error: DMG was not created at '$DMG'"; exit 1; }
[[ "$(basename "$DMG")" == "Sandshell-$VERSION.dmg" ]] || { echo "error: unexpected DMG name $DMG"; exit 1; }
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "    $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))  sha256 $SHA256"
# Project-root pointer to the newest DMG (relative; git-ignored).
ln -sfn "$DMG" Sandshell-latest.dmg

# ── Release notes (CHANGELOG.md section "## v<version> …") ───────────────────
NOTES="$WORK/notes.md"
awk -v v="$VERSION" '
  $0 ~ "^## v" v "([^0-9.]|$)" { on = 1; next }
  on && /^## / { exit }
  on { print }
' CHANGELOG.md > "$NOTES" || true
if [[ -s "$NOTES" && -n "$(tr -d '[:space:]' < "$NOTES")" ]]; then
  echo "==> Release notes: CHANGELOG.md § v$VERSION ($(grep -c . "$NOTES") lines)"
else
  echo "    ! no '## v$VERSION' section in CHANGELOG.md — using a stub note"
  printf 'Sandshell %s\n' "$VERSION" > "$NOTES"
fi
printf '\nInstall: `brew install --cask xmas/xmas/sandshell` · upgrade: `brew upgrade --cask xmas/xmas/sandshell`\n' >> "$NOTES"

# ── Updated cask ─────────────────────────────────────────────────────────────
NEW_CASK="$WORK/sandshell.rb"
if [[ -f "$CASK" ]]; then
  sed -E -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
         -e "s/^  sha256 .*$/  sha256 \"$SHA256\"/" "$CASK" > "$NEW_CASK"
  grep -q "^  version \"$VERSION\"$" "$NEW_CASK" && grep -q "^  sha256 \"$SHA256\"$" "$NEW_CASK" \
    || { echo "error: could not rewrite version/sha256 in $CASK_REL"; exit 1; }
  echo "==> Cask update ($CASK_REL):"
  diff -u "$CASK" "$NEW_CASK" | sed -n '3,$p' | grep -E '^[-+]' | sed 's/^/    /' || true
fi

# ── Publish ──────────────────────────────────────────────────────────────────
if [[ $DRY_RUN == 1 ]]; then
  echo ""
  echo "==> Dry run — a real run would now execute:"
else
  echo "==> Publishing"
fi
# 1. Commit the bump + tag here (local; reversible until pushed).
COMMIT_PATHS=(project.yml)
[[ -n "$(git status --porcelain -- CHANGELOG.md)" ]] && COMMIT_PATHS+=(CHANGELOG.md)
run git -C "$ROOT" add -- "${COMMIT_PATHS[@]}"
run git -C "$ROOT" commit -m "Release $VERSION" -- "${COMMIT_PATHS[@]}"
YML_BACKUP=""   # committed — don't restore from here on
run git -C "$ROOT" tag -a "$APP_TAG" -m "Sandshell $VERSION"
# 2. Public DMG on the tap repo.
run gh release create "$TAG" -R "$TAP_REPO" "$ROOT/$DMG" \
    --title "Sandshell $VERSION" --notes-file "$NOTES"
# 3. Cask.
run cp "$NEW_CASK" "$CASK"
run git -C "$TAP_DIR" add -- "$CASK_REL"
run git -C "$TAP_DIR" commit -m "sandshell $VERSION" -- "$CASK_REL"
run git -C "$TAP_DIR" push origin main
# 4. This repo.
run git -C "$ROOT" push origin main
run git -C "$ROOT" push origin "$APP_TAG"
# 5. Sandshell's kits, public at xmas/sandshell-kits (for sbx clients and the
#    cloud; the app uses its bundled copy). A failure here doesn't undo the release.
if [[ -d "${SANDSHELL_KITS_DIR:-$ROOT/../sandshell-kits}/.git" ]]; then
  "$ROOT/scripts/publish-kits.sh" $([[ $DRY_RUN == 1 ]] && echo --dry-run) "$VERSION" \
    || echo "⚠️  publishing kits failed — run scripts/publish-kits.sh $VERSION"
else
  echo "    (no ../sandshell-kits clone; kits not published)"
fi

echo ""
if [[ $DRY_RUN == 1 ]]; then
  echo "✅ Dry run complete for Sandshell $VERSION — nothing was published."
  echo "   DMG: $DMG  sha256 $SHA256"
  echo "   (notes file and new cask above were in a temp dir and have been removed)"
else
  echo "✅ Released Sandshell $VERSION"
  echo "   Release: https://github.com/$TAP_REPO/releases/tag/$TAG"
  echo "   Users:   brew update && brew upgrade --cask xmas/xmas/sandshell"
fi
