#!/usr/bin/env bash
# Build the release archive of the skill folder and print its sha256.
#
# Usage: bash build/build-release.sh [OUT_DIR]      (default: ./dist)
# Output: OUT_DIR/portable-verification-skill-v<VERSION>.tar.gz and a .sha256 file next to it.
#
# The archive holds only skills/portable-verification/ (not install.sh), so the hash pinned
# inside install.sh does not depend on install.sh itself. File order, owner, mode, mtime and
# gzip header are fixed so that the same input and the same tar/gzip give the same bytes.
# Different tar/gzip implementations may still produce different bytes; the hash that matters
# is the one of the archive that is uploaded to the release.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL="$ROOT/skills/portable-verification"
NAME=portable-verification
[ -f "$SKILL/VERSION" ] || { echo "build: missing $SKILL/VERSION" >&2; exit 1; }
version=$(tr -d '[:space:]' < "$SKILL/VERSION")
OUT_DIR=${1:-$ROOT/dist}
mkdir -p "$OUT_DIR"; OUT_DIR=$(cd "$OUT_DIR" && pwd)
archive="$OUT_DIR/$NAME-skill-v$version.tar.gz"

stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
mkdir "$stage/$NAME"

# Copy every regular file, with normalised modes (755 if executable, else 644).
(cd "$SKILL" && find . -type f ! -name '.DS_Store' | LC_ALL=C sort) > "$stage/files.txt"
while IFS= read -r f; do
  f=${f#./}
  mkdir -p "$stage/$NAME/$(dirname "$f")"
  cp "$SKILL/$f" "$stage/$NAME/$f"
  if [ -x "$SKILL/$f" ]; then chmod 755 "$stage/$NAME/$f"; else chmod 644 "$stage/$NAME/$f"; fi
done < "$stage/files.txt"
find "$stage/$NAME" -type d -exec chmod 755 {} +
find "$stage/$NAME" -exec env TZ=UTC touch -t 202001010000 {} +

(cd "$stage" && find "$NAME" -type f | LC_ALL=C sort > list.txt)

if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  owner_args="--owner=0 --group=0 --numeric-owner"
else
  owner_args="--uid 0 --gid 0 --uname root --gname root"
fi
# shellcheck disable=SC2086
(cd "$stage" && COPYFILE_DISABLE=1 tar --format=ustar $owner_args -cf - -T list.txt) | gzip -n -9 > "$archive"

if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum "$archive" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then sum=$(shasum -a 256 "$archive" | cut -d' ' -f1)
else echo "build: neither sha256sum nor shasum found" >&2; exit 1; fi
printf '%s  %s\n' "$sum" "$(basename "$archive")" > "$archive.sha256"
echo "archive: $archive"
echo "sha256:  $sum"
