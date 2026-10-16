#!/usr/bin/env bash
# Publish kits/ to the public repo xmas/sandshell-kits, tagged v<version>, so
# sbx clients (and Docker Cloud Sandboxes) can use them by git ref:
#   git+https://github.com/xmas/sandshell-kits.git#ref=v<version>&dir=sandshell-claude
# The app itself uses its bundled copy; this is for everyone else.
#
# Usage: scripts/publish-kits.sh [--dry-run] <version>
# Env:   SANDSHELL_KITS_DIR  local clone of xmas/sandshell-kits (default ../sandshell-kits)
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=1; shift; }
VERSION="${1:?usage: scripts/publish-kits.sh [--dry-run] <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KITS_DIR="${SANDSHELL_KITS_DIR:-$ROOT/../sandshell-kits}"
TAG="v$VERSION"

run() { if [[ $DRY_RUN == 1 ]]; then echo "  + $*"; else "$@"; fi; }

[[ -d "$KITS_DIR/.git" ]] || { echo "no clone at $KITS_DIR (gh repo clone xmas/sandshell-kits \"$KITS_DIR\")" >&2; exit 1; }
[[ -z "$(git -C "$KITS_DIR" status --porcelain)" ]] || { echo "$KITS_DIR has uncommitted changes" >&2; exit 1; }
[[ $DRY_RUN == 1 ]] || git -C "$KITS_DIR" pull -q --ff-only origin main
# A published tag is what people pin: never move it to a different commit.
if git -C "$KITS_DIR" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "$TAG is already published at github.com/xmas/sandshell-kits; leaving it as it is"
  exit 0
fi

for kit in "$ROOT"/kits/*/; do
  sbx kit validate "$kit" >/dev/null || { echo "kit $(basename "$kit") doesn't validate" >&2; exit 1; }
done

# Mirror the kit directories (README.md in the clone is its own); a kit gone
# from kits/ goes from the clone too.
for kit in "$ROOT"/kits/*/; do
  name="$(basename "$kit")"
  run rsync -a --delete "$kit" "$KITS_DIR/$name/"
done
for dir in "$KITS_DIR"/*/; do
  [[ -d "$ROOT/kits/$(basename "$dir")" ]] || run rm -rf "$dir"
done
# Point the README's examples at this tag.
[[ -f "$KITS_DIR/README.md" ]] && run sed -i '' -E "s/ref=v[0-9][0-9.]*/ref=$TAG/g" "$KITS_DIR/README.md"

if [[ $DRY_RUN == 0 && -z "$(git -C "$KITS_DIR" status --porcelain)" ]] && git -C "$KITS_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  # Tagged here before but never pushed (the remote lacks it, checked above): push now.
  git -C "$KITS_DIR" push -q origin main && git -C "$KITS_DIR" push -q origin "$TAG"
  echo "published kits at github.com/xmas/sandshell-kits ($TAG)"
  exit 0
fi
run git -C "$KITS_DIR" add -A
if [[ $DRY_RUN == 1 ]] || [[ -n "$(git -C "$KITS_DIR" status --porcelain)" ]]; then
  run git -C "$KITS_DIR" commit -qm "Sandshell $VERSION kits"
fi
run git -C "$KITS_DIR" tag "$TAG"
run git -C "$KITS_DIR" push -q origin main
run git -C "$KITS_DIR" push -q origin "$TAG"
echo "published kits at github.com/xmas/sandshell-kits ($TAG)"
