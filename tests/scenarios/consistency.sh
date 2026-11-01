#!/usr/bin/env bash
# Repository consistency: README code blocks match, versions match, naming rules hold.
. "$(dirname "$0")/../lib.sh"

# fenced code blocks only (content between ``` fences, fences included)
blocks() { awk '/^```/{inb=!inb; print; next} inb{print}' "$1"; }
en=$(blocks "$ROOT/README.md"); ko=$(blocks "$ROOT/README.ko.md")
assert_eq "README.md and README.ko.md have identical code blocks" "$en" "$ko"

v_inst=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/install.sh")
for dir in "$ROOT"/skills/*/; do
  s=$(basename "$dir")
  v_file=$(tr -d '[:space:]' < "$dir/VERSION")
  assert_eq "install.sh VERSION equals $s VERSION" "$v_file" "$v_inst"
  name=$(sed -n 's/^name: //p' "$dir/SKILL.md" | head -n 1)
  assert_eq "$s: SKILL.md name equals folder name" "$s" "$name"
  assert_contains "$s: SKILL.md declares MIT" "$(head -n 6 "$dir/SKILL.md")" "license: MIT"
done
assert_eq "release tooling and the skills folder agree on the skills" "portable-eval portable-verification" "$(ls "$ROOT/skills" | tr '\n' ' ' | sed 's/ $//')"
assert_file "LICENSE present" "$ROOT/LICENSE"

# check-release.sh's expected CI jobs follow the matrix in ci.yml
oses=$(sed -n 's/^ *os: \[\(.*\)\]$/\1/p' "$ROOT/.github/workflows/ci.yml" | tr -d ' "')
pys=$(sed -n 's/^ *python: \[\(.*\)\]$/\1/p' "$ROOT/.github/workflows/ci.yml" | tr -d ' "')
want="lint"
IFS=','; for o in $oses; do for p in $pys; do want="$want;test ($o, $p)"; done; done; unset IFS
got=$(sed -n 's/^EXPECTED_CHECKS="\(.*\)"$/\1/p' "$ROOT/build/check-release.sh")
assert_eq "check-release EXPECTED_CHECKS matches the ci.yml matrix" "$(echo "$want" | tr ';' '\n' | sort)" "$(echo "$got" | tr ';' '\n' | sort)"

# scripts are executable in git's index
for f in install.sh build/build-release.sh build/check-release.sh skills/portable-verification/scripts/verify.sh skills/portable-verification/scripts/plant.sh skills/portable-eval/scripts/plant.sh skills/portable-eval/scripts/pe.py; do
  if [ -x "$ROOT/$f" ]; then ok "executable: $f"; else not_ok "executable: $f"; fi
done

finish_scenario
