#!/usr/bin/env bash
# portable-verification installer.
#
# Downloads the release archive of THIS version, checks its sha256 against the value pinned
# below, and only then runs plant.sh on your project. Nothing in your project is touched
# before the check passes.
#
# Usage:  bash install.sh [--archive FILE] [plant.sh options...]
#   --archive FILE   use a local archive instead of downloading (still checked against the pinned sha256)
#   anything else    passed to plant.sh, e.g. --target DIR --agent claude --pointer CLAUDE.md --ci github
#
# Prefer: download this file, read it, then run it. Piping curl into bash runs code you have not read.
#
# What the pinned hash protects: that the archive you got is the one this install.sh was released
# with (corruption, a swapped release asset). It does not protect you if the repository itself is
# compromised and install.sh and the hash are replaced together.
set -euo pipefail

VERSION="0.1.0"
ARCHIVE_SHA256="UNSET"            # filled in at release time by build/build-release.sh output
REPO="UNSET/portable-verification" # owner/name on GitHub, filled in at release time
NAME=portable-verification

die() { echo "install: $*" >&2; exit 1; }

archive_arg=""
plant_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --archive) [ $# -ge 2 ] || die "--archive needs a value"; archive_arg=$2; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) plant_args+=("$1"); shift ;;
  esac
done

[ "$ARCHIVE_SHA256" != "UNSET" ] || die "this install.sh has no pinned sha256 (development checkout). Use scripts/plant.sh from a clone, or a released install.sh."

for t in tar gzip perl; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done
if command -v sha256sum >/dev/null 2>&1; then hasher="sha256sum"
elif command -v shasum >/dev/null 2>&1; then hasher="shasum -a 256"
else die "required tool not found: sha256sum or shasum"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/archive.tar.gz"

if [ -n "$archive_arg" ]; then
  [ -f "$archive_arg" ] || die "archive not found: $archive_arg"
  cp "$archive_arg" "$archive"
else
  command -v curl >/dev/null 2>&1 || die "required tool not found: curl"
  base="${PV_BASE_URL:-https://github.com/$REPO/releases/download/v$VERSION}"
  url="$base/$NAME-skill-v$VERSION.tar.gz"
  echo "install: downloading $url"
  curl -fsSL --retry 2 -o "$archive" "$url" || die "download failed: $url (nothing was changed)"
fi

actual=$($hasher "$archive" | cut -d' ' -f1)
if [ "$actual" != "$ARCHIVE_SHA256" ]; then
  die "sha256 mismatch (nothing was changed)
  expected: $ARCHIVE_SHA256
  actual:   $actual"
fi
echo "install: sha256 ok ($ARCHIVE_SHA256)"

mkdir "$tmp/x"
tar -xzf "$archive" -C "$tmp/x" || die "cannot extract archive (nothing was changed)"
src="$tmp/x/$NAME"
[ -f "$src/SKILL.md" ] && [ -f "$src/scripts/plant.sh" ] || die "archive does not contain the expected skill folder (nothing was changed)"

# "${arr[@]}" on an empty array fails under set -u in bash 3.2, hence the length check.
if [ "${#plant_args[@]}" -gt 0 ]; then
  bash "$src/scripts/plant.sh" "${plant_args[@]}"
else
  bash "$src/scripts/plant.sh"
fi
