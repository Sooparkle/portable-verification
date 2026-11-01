#!/usr/bin/env bash
# Repository consistency: README code blocks match, versions match, naming rules hold.
. "$(dirname "$0")/../lib.sh"

# fenced code blocks only (content between ``` fences, fences included)
blocks() { awk '/^```/{inb=!inb; print; next} inb{print}' "$1"; }
en=$(blocks "$ROOT/README.md"); ko=$(blocks "$ROOT/README.ko.md")
assert_eq "README.md and README.ko.md have identical code blocks" "$en" "$ko"

v_file=$(tr -d '[:space:]' < "$SKILL/VERSION")
v_inst=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/install.sh")
assert_eq "install.sh VERSION equals skill VERSION" "$v_file" "$v_inst"

name=$(sed -n 's/^name: //p' "$SKILL/SKILL.md" | head -n 1)
assert_eq "SKILL.md name equals folder name" "$(basename "$SKILL")" "$name"
assert_contains "SKILL.md declares MIT" "$(head -n 6 "$SKILL/SKILL.md")" "license: MIT"
assert_file "LICENSE present" "$ROOT/LICENSE"

# scripts are executable in git's index
for f in install.sh build/build-release.sh skills/portable-verification/scripts/verify.sh skills/portable-verification/scripts/plant.sh; do
  if [ -x "$ROOT/$f" ]; then ok "executable: $f"; else not_ok "executable: $f"; fi
done

finish_scenario
