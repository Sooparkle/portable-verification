#!/usr/bin/env bash
# Check the release chain of a published tag. Run it after the release is published.
#
# Usage: bash build/check-release.sh vX.Y.Z [--expect-checks "a;b;..."] [--rebuild] [--require-identical]
#   (job names contain commas, e.g. "test (ubuntu-latest, 3.9)", so the list separator is ";")
#
# Checks (any failure = exit 1):
#   1. the local tag and the tag in REPO (the repository install.sh names, where CI and the release are
#      looked up) point to the same commit; origin is not used, it can be a fork
#   2. every expected CI check run exists on exactly that commit, and every check run there succeeded
#      (default list = EXPECTED_CHECKS below, which a test keeps in step with .github/workflows/ci.yml)
#   3. install.sh as of the tag has pinned sha256 values (no UNSET) and a VERSION equal to the tag
#   4. the release has the archive of each pinned skill, and sha256(downloaded asset) == the pin
#   5. each asset holds exactly one top-level folder <skill>/, only regular files and folders, and its
#      content (files, bytes, executable bits) equals skills/<skill>/ at the tag
#   6. (--rebuild) the tag is rebuilt locally; reports whether the archive bytes are identical.
#      Different tar/gzip implementations can give different bytes, so a difference is a warning
#      unless --require-identical is given. Check 5 already ties the asset to the tag's source.
# Needs: git, gh (authenticated), tar, shasum or sha256sum. Reads only; changes nothing in the repository.
# Tests: CHECK_RELEASE_REMOTE overrides the URL used for check 1 (default https://github.com/<REPO>.git).
set -uo pipefail

EXPECTED_CHECKS="lint;test (ubuntu-latest, 3.9);test (ubuntu-latest, 3.13);test (macos-latest, 3.9);test (macos-latest, 3.13)"

tag=${1:-}; shift || true
rebuild=0; require_identical=0; expected=$EXPECTED_CHECKS
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) rebuild=1; shift ;;
    --require-identical) rebuild=1; require_identical=1; shift ;;
    --expect-checks) [ $# -ge 2 ] || { echo "check-release: --expect-checks needs a value" >&2; exit 2; }; expected=$2; shift 2 ;;
    *) echo "check-release: unknown option: $1" >&2; exit 2 ;;
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

# 1. the tag in REPO is the same commit (the same repository CI and the release are read from below)
remote_url=${CHECK_RELEASE_REMOTE:-https://github.com/$repo.git}
remote=$(git ls-remote --tags "$remote_url" "refs/tags/$tag" "refs/tags/$tag^{}" 2>/dev/null)
remote_commit=$(echo "$remote" | awk '$2 ~ /\^\{\}$/ {print $1}')
[ -n "$remote_commit" ] || remote_commit=$(echo "$remote" | awk 'NR==1 {print $1}')
if [ -z "$remote_commit" ]; then fail "tag $tag not found in $repo"
elif [ "$remote_commit" = "$commit" ]; then pass "tag in $repo points to the same commit"
else fail "tag in $repo points to $remote_commit, local tag to $commit"; fi

# 2. CI on exactly the tagged commit: every expected job is there, and everything there succeeded
runs=$(gh api "repos/$repo/commits/$commit/check-runs?per_page=100" --jq '.check_runs[] | .name + "\t" + (.conclusion // "pending")' 2>/dev/null)
if [ -z "$runs" ]; then fail "no CI check runs found for $commit"
else
  printf '%s\n' "$runs" | sed 's/^/        CI: /'
  if printf '%s\n' "$runs" | grep -qv "$(printf '\t')success$"; then fail "not every check run on $commit succeeded"; else pass "every check run on the tagged commit succeeded"; fi
  missing=""
  IFS=';'; for want in $expected; do
    printf '%s\n' "$runs" | cut -f1 | grep -qxF "$want" || missing="$missing [$want]"
  done; unset IFS
  [ -z "$missing" ] && pass "all expected CI jobs are present ($expected)" || fail "expected CI jobs missing:$missing"
fi

# 3. release assets against the pins
for p in $pins; do
  skill=${p%%:*}; want=${p#*:}
  asset="$skill-skill-v$version.tar.gz"
  if gh release download "$tag" --repo "$repo" -p "$asset" -D "$tmp" >/dev/null 2>&1 && [ -f "$tmp/$asset" ]; then
    got=$(sha_of "$tmp/$asset")
    [ "$got" = "$want" ] && pass "$asset: sha256 of the release asset equals the pin ($want)" || fail "$asset: asset sha256 $got != pin $want"
    # 5. the asset's content equals the tag's source for that skill
    mkdir -p "$tmp/a-$skill" "$tmp/s-$skill"
    tar -xzf "$tmp/$asset" -C "$tmp/a-$skill" 2>/dev/null || fail "$asset: cannot extract"
    git archive "$tag" "skills/$skill" | tar -x -C "$tmp/s-$skill"
    top=$(ls -A "$tmp/a-$skill")
    [ "$top" = "$skill" ] || fail "$asset: top level must be only $skill/, found: $(echo "$top" | tr '\n' ' ')"
    odd=$(find "$tmp/a-$skill" -mindepth 1 ! -type f ! -type d)
    [ -z "$odd" ] || fail "$asset: holds links or special files: $(echo "$odd" | sed "s|$tmp/a-$skill/||" | tr '\n' ' ')"
    if diff -r "$tmp/a-$skill/$skill" "$tmp/s-$skill/skills/$skill" >/dev/null 2>&1; then
      xa=$(cd "$tmp/a-$skill/$skill" && find . -type f -perm -u+x | LC_ALL=C sort)
      xs=$(cd "$tmp/s-$skill/skills/$skill" && find . -type f -perm -u+x | LC_ALL=C sort)
      [ "$xa" = "$xs" ] && pass "$asset: content (files, bytes, executable bits) equals skills/$skill at $tag" \
                        || fail "$asset: executable bits differ from skills/$skill at $tag"
    else
      fail "$asset: content differs from skills/$skill at $tag"
    fi
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
