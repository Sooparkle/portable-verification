#!/usr/bin/env bash
# Shared helpers for scenario files. Written for bash 3.2+.
# shellcheck disable=SC2034
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$ROOT/skills/portable-verification"
VERIFY="$SKILL/scripts/verify.sh"
PLANT="$SKILL/scripts/plant.sh"
BASH_BIN=${BASH_BIN:-$BASH}

# Keep the host environment from leaking into the code under test.
unset BASE_REF TESTS_REVIEWED CHECK_TIMEOUT EVIDENCE_ROOT FLAG_PATH_REGEX VERIFY_ROOT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0

ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; [ -n "${2:-}" ] && echo "#   $2"; FAILS=$((FAILS + 1)); return 0; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected [$2] got [$3]"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 400)" ;; esac
}
assert_not_contains() { # name haystack needle
  case "$2" in *"$3"*) not_ok "$1" "unexpected [$3] in: $(printf '%s' "$2" | head -c 400)" ;; *) ok "$1" ;; esac
}
assert_file() { if [ -e "$2" ]; then ok "$1"; else not_ok "$1" "missing file: $2"; fi; }
assert_no_file() { if [ ! -e "$2" ]; then ok "$1"; else not_ok "$1" "unexpected file: $2"; fi; }

sum256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fingerprint DIR: names and contents of everything below DIR (ignoring .git)
fingerprint() {
  (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort &&
   find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
     printf '%s %s\n' "$(sum256 "$f")" "$f"; done)
}

new_repo() { # name -> path of a fresh git repo on branch main with one commit
  local d="$WORK/$1"
  mkdir -p "$d"
  (cd "$d" && git init -q -b main && echo "# $1" > README.md && git add -A && git commit -q -m init)
  echo "$d"
}
commit_all() { (cd "$1" && git add -A && git commit -q -m "${2:-change}"); }

# repo_with_checks NAME 'checks.txt content' -> repo where checks.txt is already committed
repo_with_checks() {
  local d
  d=$(new_repo "$1")
  mkdir -p "$d/.verification"
  printf '%s\n' "$2" > "$d/.verification/checks.txt"
  commit_all "$d" "add checks"
  echo "$d"
}

# run_verify DIR [VAR=value ...] -> sets OUT (stdout+stderr) and CODE
run_verify() {
  local d=$1; shift
  OUT=$(cd "$d" && env ${1+"$@"} "$BASH_BIN" "$VERIFY" 2>&1 < /dev/null); CODE=$?
}
latest_dir() { echo "$1/$(cat "$1/.verification/evidence/LATEST")"; }

# run_plant [args...] -> sets OUT and CODE
run_plant() { OUT=$("$BASH_BIN" "$PLANT" "$@" 2>&1 < /dev/null); CODE=$?; }

finish_scenario() { echo "# scenario done: $FAILS failure(s)"; [ "$FAILS" -eq 0 ]; }
