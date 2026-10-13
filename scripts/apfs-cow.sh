#!/bin/bash
#
# apfs-cow.sh — report whether the files in a folder are APFS clones right now.
#
# For every file it asks the filesystem how many of that file's bytes are
# PRIVATE (not shared with any other file) via getattrlist ATTR_CMNEXT_PRIVATESIZE.
#   • private ≈ 0            -> a live copy-on-write clone: it shares all its
#                               blocks with another file (its source), costing
#                               ~0 extra disk until one side is modified.
#   • private ≈ file size    -> standalone: it owns all its blocks (a full copy,
#                               or a clone whose source was deleted / rewritten,
#                               or a copy from another volume — clones can't
#                               cross volumes).
#   • in between             -> partially split (some blocks COW-broken by edits).
#
# No source file needed, no copying, deterministic, works at any size.
#
# Usage:  ./apfs-cow.sh [-v] <folder>
#         -v  print per-file metadata (provenance, timestamps, raw sizes)
#
set -u
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

VERBOSE=0
DIR=""
for arg in "$@"; do
  case "$arg" in
    -v) VERBOSE=1 ;;
    -*) echo "unknown flag: $arg" >&2; echo "usage: $0 [-v] <folder>" >&2; exit 1 ;;
    *)  if [ -z "$DIR" ]; then DIR="$arg"
        else echo "usage: $0 [-v] <folder>" >&2; exit 1; fi ;;
  esac
done

if [ -z "$DIR" ]; then
  echo "usage: $0 [-v] <folder>   (reports clone status of every file in that folder)"; exit 1
fi
if [ ! -d "$DIR" ]; then
  echo "error: no such folder: $DIR" >&2
  echo "usage: $0 [-v] <folder>" >&2
  exit 1
fi
DIR="${DIR%/}"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'
  CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=; DIM=; GRN=; YEL=; CYN=; RST=
fi

DEV="$(df "$DIR" | awk 'NR==2{print $1}')"
FS="$(diskutil info "$DEV" 2>/dev/null \
      | awk -F: '/File System Personality/{gsub(/^[ \t]+/,"",$2);print $2}')"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# C helper: print a file's PRIVATE (unshared) byte count via ATTR_CMNEXT_PRIVATESIZE.
cat > "$TMP/priv.c" <<'C'
#include <sys/attr.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
int main(int argc, char **argv) {
    struct attrlist al; memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.forkattr = ATTR_CMNEXT_PRIVATESIZE;
    struct __attribute__((packed)) { uint32_t len; off_t priv; } buf;
    if (getattrlist(argv[1], &al, &buf, sizeof(buf), FSOPT_ATTR_CMN_EXTENDED) != 0) return 3;
    printf("%lld\n", (long long)buf.priv);
    return 0;
}
C
PRIV="$TMP/priv"
cc -O2 -o "$PRIV" "$TMP/priv.c" 2>/dev/null \
  || { echo "error: cannot compile helper (need Xcode command line tools)"; exit 1; }

bar()   { i=0; while [ "$i" -lt "$1" ]; do printf '─'; i=$((i+1)); done; }
padr()  { s="$1"; pad=$(( $2 - ${#s} )); [ "$pad" -lt 0 ] && pad=0; printf '%s%*s' "$s" "$pad" ""; }
trunc() { n="$1"; if [ "${#n}" -gt "$W_FILE" ]; then printf '%s…' "${n:0:$((W_FILE-1))}"; else printf '%s' "$n"; fi; }
human() { awk -v b="$1" 'BEGIN{
  if (b+0==0){print "0 B";exit}
  split("B KB MB GB TB",u," "); i=1; s=b+0
  while(s>=1024&&i<5){s/=1024;i++}
  printf (i==1?"%d %s":"%.1f %s"),s,u[i]
}'; }

W_FILE=40; W_SIZE=9; W_LOCAL=9; W_SH=7; W_V=22

echo
printf "%s  APFS clone status — %s%s\n" "$BOLD" "$DIR" "$RST"
printf "%s  volume %s (%s)\n" "$DIM" "$DEV" "${FS:-unknown fs}"
printf "  Size = logical file size  •  Local = private bytes actually on disk (0 = live COW clone)%s\n" "$RST"
case "$FS" in *APFS*) ;; *) printf "%s  ⚠ not APFS — files here cannot be clones%s\n" "$YEL" "$RST";; esac
echo

TB="$(bar $((W_FILE+2)))"
TS="$(bar $((W_SIZE+2)))"
TL="$(bar $((W_LOCAL+2)))"
TH="$(bar $((W_SH+2)))"
TV="$(bar $((W_V+2)))"

printf "┌%s┬%s┬%s┬%s┬%s┐\n" "$TB" "$TS" "$TL" "$TH" "$TV"
printf "│ %s │ %${W_SIZE}s │ %${W_LOCAL}s │ %${W_SH}s │ %-${W_V}s │\n" \
  "$(padr File $W_FILE)" "Size" "Local" "Shared" "Status"
printf "├%s┼%s┼%s┼%s┼%s┤\n" "$TB" "$TS" "$TL" "$TH" "$TV"

found=0; clones=0; standalone=0
for f in "$DIR"/*; do
  [ -f "$f" ] || continue
  found=1
  bytes=$(stat -f '%z' "$f")
  priv=$("$PRIV" "$f" 2>/dev/null)
  name="$(trunc "$(basename "$f")")"; size="$(human "$bytes")"

  if [ -z "$priv" ]; then
    local_sz="—"; sh="—"; col="$DIM"; status="n/a (query failed)"
  elif [ "$bytes" -eq 0 ]; then
    local_sz="0 B"; sh="—"; col="$DIM"; status="empty file"
  else
    local_sz="$(human "$priv")"
    pct=$(awk -v s="$bytes" -v p="$priv" \
      'BEGIN{v=(s-p)*100/s; if(v<0)v=0; if(v>100)v=100; printf "%d", v+0.5}')
    sh="${pct}%"
    if   [ "$pct" -ge 99 ]; then col="$GRN"; status="CLONE — shares blocks"; clones=$((clones+1))
    elif [ "$pct" -le 1  ]; then col="$YEL"; status="standalone copy";       standalone=$((standalone+1))
    else                          col="$CYN"; status="partially COW-split";  standalone=$((standalone+1))
    fi
  fi

  printf "│ %s │ %${W_SIZE}s │ %${W_LOCAL}s │ %${W_SH}s │ %b%s%b │\n" \
    "$(padr "$name" $W_FILE)" "$size" "$local_sz" "$sh" \
    "$col" "$(padr "$status" $W_V)" "$RST"
done

printf "└%s┴%s┴%s┴%s┴%s┘\n" "$TB" "$TS" "$TL" "$TH" "$TV"

[ "$found" -eq 1 ] || { echo; echo "  (no regular files in $DIR)"; echo; exit 0; }

echo
if [ "$clones" -gt 0 ] && [ "$standalone" -eq 0 ]; then
  printf "  %s✓ COW working:%s all %d file(s) are live clones — each shares its blocks with its source.\n" \
    "$GRN" "$RST" "$clones"
elif [ "$clones" -gt 0 ]; then
  printf "  %s✓ COW working:%s %d clone(s), %d standalone.\n" "$GRN" "$RST" "$clones" "$standalone"
  printf "  %sStandalone files own all their blocks — a full copy, an edited/rewritten clone,\n" "$DIM"
  printf "  or a copy from another volume (clones can't cross volumes, e.g. a DMG).%s\n" "$RST"
else
  printf "  %sNo clones here — every file owns its own blocks.%s\n" "$YEL" "$RST"
fi
echo

# ── Verbose per-file detail ──────────────────────────────────────────────────
if [ "$VERBOSE" -eq 1 ]; then
  printf "%s  Verbose detail%s\n" "$BOLD" "$RST"
  SEP="  ─────────────────────────────────────────────────────────────────────"

  _field() { printf "  %-14s %s\n" "$1" "$2"; }

  PROVENANCE="$DIR/.provenance"

  # Look up the source path recorded by Sandshell at drag time.
  _provenance() {
    local fname="$1"
    [ -f "$PROVENANCE" ] || { printf '—  (no .provenance file — drop a file in Sandshell to start recording)'; return; }
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
entry = data.get(sys.argv[2], {})
src = entry.get('source', '')
at  = entry.get('droppedAt', '')
if src:
    print(src + ('  (dropped ' + at + ')' if at else ''))
else:
    print('—  (not in .provenance — file predates this feature)')
" "$PROVENANCE" "$fname" 2>/dev/null || printf '—  (parse error)'
  }

  # Decode com.apple.metadata:kMDItemWhereFroms bplist → list of URLs
  _wherefroms() {
    local f="$1"
    local raw
    raw=$(xattr -px "com.apple.metadata:kMDItemWhereFroms" "$f" 2>/dev/null) || { echo "—"; return; }
    [ -z "$raw" ] && { echo "—"; return; }
    python3 - "$raw" 2>/dev/null <<'PY' || echo "(bplist present — decode failed)"
import sys, plistlib
data = bytes.fromhex(sys.argv[1].replace(' ', '').replace('\n', ''))
urls = plistlib.loads(data)
print(', '.join(str(u) for u in urls[:3]))
PY
  }

  # Decode com.apple.quarantine → originating app name
  _quarantine() {
    local f="$1"
    local qt
    qt=$(xattr -p com.apple.quarantine "$f" 2>/dev/null) || { echo "—"; return; }
    [ -z "$qt" ] && { echo "—"; return; }
    local app
    app=$(printf '%s' "$qt" | awk -F';' '{print $3}')
    printf '%s  (raw: %s)' "${app:-unknown}" "$qt"
  }

  for f in "$DIR"/*; do
    [ -f "$f" ] || continue
    fname="$(basename "$f")"
    bytes=$(stat -f '%z' "$f")
    mtime=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$f")
    priv=$("$PRIV" "$f" 2>/dev/null)

    echo
    echo "$SEP"
    printf "  %s%s%s\n" "$BOLD" "$fname" "$RST"
    echo "$SEP"

    _field "Full path:"   "$f"
    _field "File size:"   "$(human "$bytes")  (${bytes} bytes)"

    if [ -z "$priv" ]; then
      _field "Local disk:" "— (getattrlist query failed)"
    elif [ "$bytes" -eq 0 ]; then
      _field "Local disk:" "0 B  (empty file)"
    else
      pct=$(awk -v s="$bytes" -v p="$priv" \
        'BEGIN{v=(s-p)*100/s; if(v<0)v=0; if(v>100)v=100; printf "%d", v+0.5}')
      if [ "$pct" -ge 99 ]; then
        _field "Local disk:" "${GRN}0 B${RST}  (100% COW-shared — clone owns no blocks)"
      elif [ "$pct" -le 1 ]; then
        _field "Local disk:" "$(human "$priv")  (${priv} private bytes — standalone)"
      else
        _field "Local disk:" "$(human "$priv")  (${priv} private bytes — ${pct}% COW-split)"
      fi
    fi

    _field "Modified:"    "$mtime"

    # Provenance via xattrs (may be absent on virtiofs / non-APFS)
    if command -v xattr >/dev/null 2>&1; then
      wf="$(_wherefroms "$f")"
      qt="$(_quarantine "$f")"
      _field "Origin URL:"  "$wf"
      _field "Quarantine:"  "$qt"
    else
      _field "Provenance:"  "— (xattr not available on this filesystem)"
    fi

    _field "Source path:" "$(_provenance "$fname")"
  done

  echo
  echo "$SEP"
  echo
fi
