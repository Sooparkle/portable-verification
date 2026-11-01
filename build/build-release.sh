#!/usr/bin/env bash
# Build the release archive of each skill folder and print its sha256.
#
# Usage: bash build/build-release.sh [OUT_DIR] [SKILL]     (default: ./dist, every folder under skills/)
# Output: OUT_DIR/<skill>-skill-v<VERSION>.tar.gz and a .sha256 file next to each archive.
#
# An archive holds only skills/<skill>/ (never install.sh), so a hash pinned inside install.sh
# does not depend on install.sh itself. File order, owner, mode, mtime and gzip header are
# fixed so that the same input and the same tar/gzip give the same bytes. Different tar/gzip
# implementations may still produce different bytes; the hash that matters is the one of the
# archive that is uploaded to the release.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${1:-$ROOT/dist}
ONLY=${2:-}
mkdir -p "$OUT_DIR"; OUT_DIR=$(cd "$OUT_DIR" && pwd)

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo "build: neither sha256sum nor shasum found" >&2; return 1; fi
}

if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  owner_args="--owner=0 --group=0 --numeric-owner"
else
  owner_args="--uid 0 --gid 0 --uname root --gname root"
fi

build_one() { # NAME
  local NAME=$1 SKILL="$ROOT/skills/$1" version stage archive f
  [ -f "$SKILL/VERSION" ] || { echo "build: missing $SKILL/VERSION" >&2; return 1; }
  version=$(tr -d '[:space:]' < "$SKILL/VERSION")
  archive="$OUT_DIR/$NAME-skill-v$version.tar.gz"
  stage=$(mktemp -d)
  mkdir "$stage/$NAME"
  # Copy every regular file, with normalised modes (755 if executable, else 644).
  (cd "$SKILL" && find . -type f ! -name '.DS_Store' ! -name '*.pyc' ! -path '*/__pycache__/*' | LC_ALL=C sort) > "$stage/files.txt"
  while IFS= read -r f; do
    f=${f#./}
    mkdir -p "$stage/$NAME/$(dirname "$f")"
    cp "$SKILL/$f" "$stage/$NAME/$f"
    if [ -x "$SKILL/$f" ]; then chmod 755 "$stage/$NAME/$f"; else chmod 644 "$stage/$NAME/$f"; fi
  done < "$stage/files.txt"
  find "$stage/$NAME" -type d -exec chmod 755 {} +
  find "$stage/$NAME" -exec env TZ=UTC touch -t 202001010000 {} +
  (cd "$stage" && find "$NAME" -type f | LC_ALL=C sort > list.txt)
  # shellcheck disable=SC2086
  (cd "$stage" && COPYFILE_DISABLE=1 tar --format=ustar $owner_args -cf - -T list.txt) | gzip -n -9 > "$archive"
  rm -rf "$stage"
  local sum
  sum=$(sha_of "$archive")
  printf '%s  %s\n' "$sum" "$(basename "$archive")" > "$archive.sha256"
  echo "archive: $archive"
  echo "sha256:  $sum  $(basename "$archive")"
}

if [ -n "$ONLY" ]; then
  [ -d "$ROOT/skills/$ONLY" ] || { echo "build: no such skill: $ONLY" >&2; exit 1; }
  build_one "$ONLY"
else
  for d in "$ROOT"/skills/*/; do build_one "$(basename "$d")"; done
fi
