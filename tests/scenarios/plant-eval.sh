#!/usr/bin/env bash
# portable-eval plant.sh: what it creates, what it keeps, what --force replaces, what it rejects.
. "$(dirname "$0")/../lib.sh"
PLANT_E="$ROOT/skills/portable-eval/scripts/plant.sh"
SKILL_E="$ROOT/skills/portable-eval"
VER=$(tr -d '[:space:]' < "$SKILL_E/VERSION")
run_plant_e() { OUT=$("$BASH_BIN" "$PLANT_E" "$@" 2>&1 < /dev/null); CODE=$?; }

p=$(new_repo ev)
run_plant_e --target "$p" --agent claude --pointer CLAUDE.md --ci github
assert_eq "plant succeeds" 0 "$CODE"
assert_file "skill folder created" "$p/.claude/skills/portable-eval/SKILL.md"
assert_file "contracts shipped with the skill" "$p/.claude/skills/portable-eval/docs/contracts.md"
assert_file "pe.py planted" "$p/.eval/pe.py"
assert_file "schemas planted" "$p/.eval/schemas/manifest.schema.json"
assert_file "spec template planted" "$p/.eval/spec.json"
assert_file "system manifest template planted" "$p/.eval/system-manifest.json"
assert_file "cases dir planted" "$p/.eval/cases/.gitkeep"
assert_file "install record planted" "$p/.eval/.plant-manifest"
assert_file "trusted CI workflow planted" "$p/.github/workflows/eval.yml"
assert_contains ".gitignore ignores runs" "$(cat "$p/.gitignore")" ".eval/runs/"
assert_contains "pointer written" "$(cat "$p/CLAUDE.md")" "portable-eval:start"
assert_contains "record has the version" "$(cat "$p/.eval/.plant-manifest")" "plant_version=$VER"
assert_contains "record has the hash of pe.py" "$(cat "$p/.eval/.plant-manifest")" "$(sum256 "$p/.eval/pe.py")"
if diff -q "$SKILL_E/scripts/pe.py" "$p/.eval/pe.py" >/dev/null; then ok "planted pe.py equals the source"; else not_ok "planted pe.py equals the source"; fi

# placeholders in the templates make the gate refuse to run until a human fills them in
(cd "$p" && python3 -I .eval/pe.py validate --eval-dir .eval >/dev/null 2>&1); assert_eq "unfilled template: validate is BLOCKED" 3 "$?"
(cd "$p" && python3 -I .eval/pe.py gate all --eval-dir .eval --adapter-cmd '["true"]' >/dev/null 2>&1); assert_eq "unfilled template: gate is BLOCKED" 3 "$?"

# rerun: idempotent, user files kept, differing tool files skipped without --force
echo '{"mine": 1}' > "$p/.eval/spec.json"
echo "# my case" > "$p/.eval/cases/c.txt"
before=$(fingerprint "$p")
run_plant_e --target "$p" --agent claude --pointer CLAUDE.md --ci github
assert_eq "rerun succeeds" 0 "$CODE"
assert_eq "rerun changes nothing (except the record it rewrites identically)" "$before" "$(fingerprint "$p")"
assert_eq "pointer block exactly once" 1 "$(grep -c 'portable-eval:start' "$p/CLAUDE.md")"
echo "# local edit" >> "$p/.eval/pe.py"
echo "{}" > "$p/.eval/schemas/spec.schema.json"
run_plant_e --target "$p" --agent claude
assert_contains "edited pe.py is skipped" "$OUT" "skipped  .eval/pe.py"
assert_contains "edited schema is skipped" "$OUT" "skipped  .eval/schemas/spec.schema.json"
run_plant_e --target "$p" --agent claude --force
assert_contains "--force replaces pe.py" "$OUT" "replaced .eval/pe.py"
if diff -q "$SKILL_E/scripts/pe.py" "$p/.eval/pe.py" >/dev/null; then ok "pe.py restored by --force"; else not_ok "pe.py restored by --force"; fi
assert_eq "--force keeps the user's spec.json" '{"mine": 1}' "$(cat "$p/.eval/spec.json")"
assert_file "--force keeps the user's cases" "$p/.eval/cases/c.txt"

# --check writes nothing and rejects what a real run would reject
p=$(new_repo chk)
before=$(fingerprint "$p")
run_plant_e --target "$p" --agent claude --check
assert_eq "--check succeeds" 0 "$CODE"
assert_contains "--check says so" "$OUT" "check ok"
assert_eq "--check writes nothing" "$before" "$(fingerprint "$p")"
for bad in "--agent bogus" "--ci gitlab" "--nonsense"; do
  # shellcheck disable=SC2086
  run_plant_e --target "$p" --check $bad
  assert_eq "--check rejects '$bad'" 1 "$CODE"
done
run_plant_e --target "$WORK/nope" --check;       assert_eq "missing target rejected" 1 "$CODE"
run_plant_e --target "$SKILL_E";                 assert_eq "target = skill source folder rejected" 1 "$CODE"
run_plant_e --target;                            assert_eq "option without value rejected" 1 "$CODE"
assert_eq "rejections wrote nothing" "$before" "$(fingerprint "$p")"

# without python3 the plant refuses (PATH farm with no python3)
mkdir -p "$WORK/farm-nopy"
for tool in bash env dirname cat sed grep tr cut; do ln -sf "$(command -v $tool)" "$WORK/farm-nopy/$tool"; done
OUT=$(env -i PATH="$WORK/farm-nopy" "$BASH_BIN" "$PLANT_E" --target "$p" --check 2>&1 </dev/null); CODE=$?
assert_eq "no python3: plant refuses" 1 "$CODE"
assert_contains "no python3: says why" "$OUT" "python3 not found"

mkdir -p "$WORK/my app"
run_plant_e --target "$WORK/my app" --agent claude
assert_eq "target path with a space" 0 "$CODE"

finish_scenario
