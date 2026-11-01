#!/usr/bin/env bash
# portable-verification / portable-eval installer.
#
# Downloads the release archive(s) of THIS version, checks each sha256 against the value pinned
# below, runs `plant.sh --check` for every selected skill, and only then plants them in your
# project. Nothing in your project is touched before every archive and every check has passed.
#
# Usage:  bash install.sh [--skill verification|eval|both] [--archive FILE | --archive-dir DIR] [plant.sh options...]
#   --skill NAME       which skill to install (default: verification)
#   --archive FILE     use a local archive instead of downloading (only with a single skill)
#   --archive-dir DIR  use local archives named <skill>-skill-v<VERSION>.tar.gz from DIR
#   anything else      passed to plant.sh, e.g. --target DIR --agent claude --pointer CLAUDE.md --ci github
#
# Archives are always checked against the pinned sha256, also when they are local.
# Prefer: download this file, read it, then run it. Piping curl into bash runs code you have not read.
#
# What the pinned hash protects: that the archive you got is the one this install.sh was released
# with (corruption, a swapped release asset). It does not protect you if the repository itself is
# compromised and install.sh and the hash are replaced together.
#
# Not transactional: all checks happen before the first write, but an I/O error while writing
# (disk full, ...) can leave a partial install. plant.sh is idempotent, so run it again.
set -euo pipefail

VERSION="0.2.0"
SHA256_VERIFICATION="UNSET"       # sha256 of portable-verification-skill-v$VERSION.tar.gz (build/build-release.sh)
SHA256_EVAL="UNSET"               # sha256 of portable-eval-skill-v$VERSION.tar.gz
REPO="Sooparkle/portable-verification"      # owner/name on GitHub

die() { echo "install: $*" >&2; exit 1; }

skill_arg="verification"; archive_arg=""; archive_dir=""
plant_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --skill) [ $# -ge 2 ] || die "--skill needs a value"; skill_arg=$2; shift 2 ;;
    --archive) [ $# -ge 2 ] || die "--archive needs a value"; archive_arg=$2; shift 2 ;;
    --archive-dir) [ $# -ge 2 ] || die "--archive-dir needs a value"; archive_dir=$2; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) plant_args+=("$1"); shift ;;
  esac
done

case "$skill_arg" in
  verification) skills=(portable-verification) ;;
  eval) skills=(portable-eval) ;;
  both) skills=(portable-verification portable-eval) ;;
  *) die "unknown --skill: $skill_arg (use verification, eval or both)" ;;
esac
if [ -n "$archive_arg" ] && [ "${#skills[@]}" -ne 1 ]; then die "--archive works with a single skill; use --archive-dir for both"; fi

pin_for() { case "$1" in portable-verification) echo "$SHA256_VERIFICATION" ;; portable-eval) echo "$SHA256_EVAL" ;; esac; }
for s in "${skills[@]}"; do
  [ "$(pin_for "$s")" != "UNSET" ] || die "this install.sh has no pinned sha256 for $s (development checkout). Use scripts/plant.sh from a clone, or a released install.sh."
done

for t in tar gzip perl; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done
for s in "${skills[@]}"; do
  [ "$s" = portable-eval ] || continue
  command -v python3 >/dev/null 2>&1 || die "required tool not found: python3 (portable-eval needs Python 3.9 or newer)"
done
if command -v sha256sum >/dev/null 2>&1; then hasher="sha256sum"
elif command -v shasum >/dev/null 2>&1; then hasher="shasum -a 256"
else die "required tool not found: sha256sum or shasum"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Phase 1: obtain and verify every archive, extract every archive. No write to the project yet.
for s in "${skills[@]}"; do
  archive="$tmp/$s.tar.gz"
  file="$s-skill-v$VERSION.tar.gz"
  if [ -n "$archive_arg" ]; then
    [ -f "$archive_arg" ] || die "archive not found: $archive_arg"
    cp "$archive_arg" "$archive"
  elif [ -n "$archive_dir" ]; then
    [ -f "$archive_dir/$file" ] || die "archive not found: $archive_dir/$file"
    cp "$archive_dir/$file" "$archive"
  else
    command -v curl >/dev/null 2>&1 || die "required tool not found: curl"
    base="${PV_BASE_URL:-https://github.com/$REPO/releases/download/v$VERSION}"
    echo "install: downloading $base/$file"
    curl -fsSL --retry 2 -o "$archive" "$base/$file" || die "download failed: $base/$file (nothing was changed)"
  fi
  actual=$($hasher "$archive" | cut -d' ' -f1)
  want=$(pin_for "$s")
  if [ "$actual" != "$want" ]; then
    die "sha256 mismatch for $s (nothing was changed)
  expected: $want
  actual:   $actual"
  fi
  echo "install: sha256 ok for $s ($want)"
  mkdir "$tmp/x-$s"
  tar -xzf "$archive" -C "$tmp/x-$s" || die "cannot extract $s archive (nothing was changed)"
  src="$tmp/x-$s/$s"
  [ -f "$src/SKILL.md" ] && [ -f "$src/scripts/plant.sh" ] || die "$s archive does not contain the expected skill folder (nothing was changed)"
done

# "${arr[@]}" on an empty array fails under set -u in bash 3.2, hence the length checks.
run_plant() { # SKILL [extra option]
  local s=$1 src="$tmp/x-$1/$1"; shift
  if [ "${#plant_args[@]}" -gt 0 ]; then bash "$src/scripts/plant.sh" "$@" "${plant_args[@]}"
  else bash "$src/scripts/plant.sh" "$@"; fi
}

# Phase 2: every selected skill must pass its own pre-flight check.
for s in "${skills[@]}"; do run_plant "$s" --check >/dev/null || die "pre-flight check failed for $s (nothing was changed)"; done

# Phase 3: apply.
for s in "${skills[@]}"; do run_plant "$s"; done
