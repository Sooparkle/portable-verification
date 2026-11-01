#!/usr/bin/env bash
# Check the release chain of a published tag. Run it after the release is published.
#
# Usage: bash build/check-release.sh vX.Y.Z [--rebuild] [--require-identical]
#
# Checks (any failure = exit 1):
#   1. the tag resolves to a commit, and every CI check run on exactly that commit succeeded
#   2. install.sh as of the tag has pinned sha256 values (no UNSET) and a VERSION equal to the tag
#   3. the release has the archive of each pinned skill, and sha256(downloaded asset) == the pin
#   4. (--rebuild) the tag is rebuilt locally; reports whether the bytes are identical to the asset.
#      Different tar/gzip implementations can give different bytes, so a difference is a warning
#      unless --require-identical is given.
# Needs: git, gh (authenticated), tar, shasum or sha256sum. Reads only; changes nothing in the repository.
set -uo pipefail

tag=${1:-}; shift || true
rebuild=0; require_identical=0
for a in "$@"; do
  case "$a" in
    --rebuild) rebuild=1 ;;
    --require-identical) rebuild=1; require_identical=1 ;;
    *) echo "check-release: unknown option: $a" >&2; exit 2 ;;
  esac
done
[ -n "$tag" ] || { echo "usage: check-release.sh vX.Y.Z [--rebuild] [--require-identical]" >&2; exit 2; }
for t in git gh tar; do command -v "$t" >/dev/null 2>&1 || { echo "check-release: $t not found" >&2; exit 2; }; done

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
bad=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; bad=1; }
warn() { echo "  warn  $1"; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "check-release: $tag"
commit=$(git rev-parse --verify --quiet "$tag^{commit}") || { echo "  FAIL  tag $tag does not exist locally (git fetch --tags)"; exit 1; }
echo "  tag commit: $commit"
git show "$tag:install.sh" > "$tmp/install.sh" 2>/dev/null || { echo "  FAIL  no install.sh at $tag"; exit 1; }
repo=$(sed -n 's/^REPO="\([^"]*\)".*/\1/p' "$tmp/install.sh")
version=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$tmp/install.sh")
case "$repo" in ""|UNSET*) fail "install.sh has no REPO"; exit 1 ;; esac
echo "  repository: $repo"

# 2. pins and version
[ "v$version" = "$tag" ] && pass "install.sh VERSION ($version) matches the tag" || fail "install.sh VERSION ($version) does not match $tag"
pv=$(sed -n 's/^SHA256_VERIFICATION="\([^"]*\)".*/\1/p' "$tmp/install.sh")
pe=$(sed -n 's/^SHA256_EVAL="\([^"]*\)".*/\1/p' "$tmp/install.sh")
legacy=$(sed -n 's/^ARCHIVE_SHA256="\([^"]*\)".*/\1/p' "$tmp/install.sh")
[ -z "$pv" ] && [ -n "$legacy" ] && pv=$legacy      # v0.1.0 had a single pin for portable-verification
pins=""
[ -n "$pv" ] && pins="$pins portable-verification:$pv"
[ -n "$pe" ] && pins="$pins portable-eval:$pe"
[ -n "$pins" ] || fail "no pinned sha256 found in install.sh"
for p in $pins; do
  [ "${p#*:}" = UNSET ] && fail "${p%%:*} is pinned to UNSET at $tag"
done

# 1. CI on exactly the tagged commit
runs=$(gh api "repos/$repo/commits/$commit/check-runs?per_page=100" --jq '.check_runs[] | .name + " " + (.conclusion // "pending")' 2>/dev/null)
if [ -z "$runs" ]; then fail "no CI check runs found for $commit"
else
  echo "$runs" | sed 's/^/        CI: /'
  if echo "$runs" | grep -qv ' success$'; then fail "not every check run on $commit succeeded"; else pass "all CI check runs on the tagged commit succeeded"; fi
fi

# 3. release assets against the pins
for p in $pins; do
  skill=${p%%:*}; want=${p#*:}
  asset="$skill-skill-v$version.tar.gz"
  if gh release download "$tag" --repo "$repo" -p "$asset" -D "$tmp" >/dev/null 2>&1 && [ -f "$tmp/$asset" ]; then
    got=$(sha_of "$tmp/$asset")
    [ "$got" = "$want" ] && pass "$asset: sha256 of the release asset equals the pin ($want)" || fail "$asset: asset sha256 $got != pin $want"
  else
    fail "$asset: not found among the release assets"
  fi
done

# 4. optional rebuild
if [ "$rebuild" = 1 ]; then
  mkdir -p "$tmp/src" "$tmp/rebuilt"
  git archive "$tag" | tar -x -C "$tmp/src"
  (cd "$tmp/src" && bash build/build-release.sh "$tmp/rebuilt" >/dev/null 2>&1) || fail "rebuild of $tag failed"
  for p in $pins; do
    skill=${p%%:*}; asset="$skill-skill-v$version.tar.gz"
    if [ -f "$tmp/rebuilt/$asset" ] && [ -f "$tmp/$asset" ]; then
      if cmp -s "$tmp/rebuilt/$asset" "$tmp/$asset"; then pass "$asset: rebuilt bytes are identical to the asset"
      elif [ "$require_identical" = 1 ]; then fail "$asset: rebuilt bytes differ from the asset"
      else warn "$asset: rebuilt bytes differ from the asset (can be a different tar/gzip); the pin refers to the uploaded asset"; fi
    else
      fail "$asset: cannot compare the rebuild (missing file)"
    fi
  done
fi

echo
if [ "$bad" = 0 ]; then echo "check-release: OK"; else echo "check-release: FAILED"; fi
exit "$bad"
