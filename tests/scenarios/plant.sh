#!/usr/bin/env bash
# plant.sh: what it creates, what it preserves, what --force replaces, what it rejects.
. "$(dirname "$0")/../lib.sh"

# ---- fresh project, explicit agent ------------------------------------
p=$(new_repo node)
cat > "$p/package.json" <<'JSON'
{ "name": "x", "scripts": { "test": "echo t", "typecheck": "echo tc", "build": "echo b", "lint": "echo l", "test:e2e": "echo e" } }
JSON
touch "$p/pnpm-lock.yaml"
run_plant --target "$p" --agent claude --pointer CLAUDE.md --ci github
assert_eq "plant succeeds" 0 "$CODE"
assert_file "skill folder created under .claude/skills" "$p/.claude/skills/portable-verification/SKILL.md"
assert_file "VERSION copied into the skill folder" "$p/.claude/skills/portable-verification/VERSION"
assert_file "verify.sh planted" "$p/.verification/verify.sh"
assert_file "feature-map planted" "$p/.verification/feature-map.md"
assert_file "checks.txt planted" "$p/.verification/checks.txt"
assert_file "install record planted" "$p/.verification/.plant-manifest"
assert_file "CI workflow planted" "$p/.github/workflows/verification.yml"
assert_file "pointer file created" "$p/CLAUDE.md"
checks=$(cat "$p/.verification/checks.txt")
assert_contains "package manager detected (pnpm)" "$checks" "#unit yes pnpm run test"
assert_contains "typecheck suggested" "$checks" "#typecheck yes pnpm run typecheck"
assert_contains "lint is optional" "$checks" "#lint no pnpm run lint"
assert_contains "e2e suggested" "$checks" "#e2e yes pnpm run test:e2e"
assert_contains ".gitignore ignores evidence" "$(cat "$p/.gitignore")" ".verification/evidence/"
if diff -r "$SKILL/scripts" "$p/.claude/skills/portable-verification/scripts" >/dev/null; then ok "installed scripts equal the source"; else not_ok "installed scripts equal the source"; fi
if diff -q "$SKILL/scripts/verify.sh" "$p/.verification/verify.sh" >/dev/null; then ok "planted verify.sh equals the source"; else not_ok "planted verify.sh equals the source"; fi

# suggestions are comments: nothing is enabled, so the first run is NOT RUN
OUT=$(cd "$p" && "$BASH_BIN" .verification/verify.sh 2>&1 </dev/null); CODE=$?
assert_eq "nothing enabled -> NOT RUN" 4 "$CODE"

# ---- install record ----------------------------------------------------
man=$(cat "$p/.verification/.plant-manifest")
assert_contains "record has the version" "$man" "plant_version=0.1.0"
assert_contains "record has the hash of verify.sh" "$man" "$(sum256 "$p/.verification/verify.sh")"

# ---- rerun is idempotent and keeps user files --------------------------
printf 'mine yes true\n' >> "$p/.verification/checks.txt"
echo "# my notes" >> "$p/.verification/feature-map.md"
before=$(fingerprint "$p")
run_plant --target "$p" --agent claude --pointer CLAUDE.md --ci github
assert_eq "rerun succeeds" 0 "$CODE"
assert_eq "rerun changes nothing" "$before" "$(fingerprint "$p")"
assert_contains "rerun reports 'kept' for checks.txt" "$OUT" "kept     .verification/checks.txt"
assert_eq "pointer block written exactly once" 1 "$(grep -c 'portable-verification:start' "$p/CLAUDE.md")"

# ---- differing skill folder: skipped without --force, replaced with it --
echo "# local edit" >> "$p/.claude/skills/portable-verification/SKILL.md"
echo "# local edit" >> "$p/.verification/verify.sh"
run_plant --target "$p" --agent claude
assert_contains "differing skill folder is skipped" "$OUT" "skipped  .claude/skills/portable-verification"
assert_contains "local edit survives without --force" "$(cat "$p/.claude/skills/portable-verification/SKILL.md")" "# local edit"
run_plant --target "$p" --agent claude --force
assert_contains "--force reports replaced" "$OUT" "replaced .claude/skills/portable-verification"
assert_not_contains "--force restores SKILL.md" "$(cat "$p/.claude/skills/portable-verification/SKILL.md")" "# local edit"
assert_not_contains "--force restores verify.sh" "$(cat "$p/.verification/verify.sh")" "# local edit"
assert_contains "--force keeps user checks.txt" "$(cat "$p/.verification/checks.txt")" "mine yes true"
assert_contains "--force keeps user feature-map.md" "$(cat "$p/.verification/feature-map.md")" "# my notes"

# ---- existing project files are preserved -----------------------------
p=$(new_repo preserve)
mkdir -p "$p/.github/workflows"; echo "# mine" > "$p/.github/workflows/verification.yml"
printf 'existing line' > "$p/AGENTS.md"
printf 'node_modules' > "$p/.gitignore"
run_plant --target "$p" --agent agents --pointer AGENTS.md --ci github --force
assert_eq "existing workflow is not overwritten, even with --force" "# mine" "$(cat "$p/.github/workflows/verification.yml")"
assert_contains "existing pointer file content kept" "$(cat "$p/AGENTS.md")" "existing line"
assert_contains "pointer appended" "$(cat "$p/AGENTS.md")" "portable-verification:start"
assert_contains "gitignore without trailing newline keeps old entry" "$(cat "$p/.gitignore")" "node_modules"
assert_eq "evidence entry on its own line" ".verification/evidence/" "$(tail -n 1 "$p/.gitignore")"
assert_file "agents folder used" "$p/.agents/skills/portable-verification/SKILL.md"

# ---- detection and suggestions for other ecosystems -------------------
p=$(new_repo detect)
mkdir -p "$p/.cursor"; printf '[tool.pytest.ini_options]\n' > "$p/pyproject.toml"; echo 'module x' > "$p/go.mod"
printf 'test:\n\techo\n' > "$p/Makefile"; touch "$p/Cargo.toml"
run_plant --target "$p"
assert_file "agent detected from .cursor/" "$p/.cursor/skills/portable-verification/SKILL.md"
assert_no_file "other agents not installed" "$p/.claude"
c=$(cat "$p/.verification/checks.txt")
assert_contains "pytest suggestion" "$c" "#unit-py yes python -m pytest -q"
assert_contains "go suggestion" "$c" "#unit-go yes go test ./..."
assert_contains "cargo suggestion" "$c" "#unit-rs yes cargo test"
assert_contains "make suggestion" "$c" "#make-test yes make test"

p=$(new_repo default-agent)
run_plant --target "$p"
assert_file "no hint -> .agents/skills" "$p/.agents/skills/portable-verification/SKILL.md"

# ---- rejection: nothing may be created --------------------------------
p=$(new_repo reject)
before=$(fingerprint "$p")
run_plant --target "$p" --agent bogus
assert_eq "unknown agent rejected" 1 "$CODE"
assert_eq "unknown agent leaves the project untouched" "$before" "$(fingerprint "$p")"
run_plant --target "$p" --nonsense
assert_eq "unknown option rejected" 1 "$CODE"
run_plant --target "$p" --ci gitlab --agent claude
assert_eq "unsupported --ci rejected" 1 "$CODE"
run_plant --target "$WORK/does-not-exist"
assert_eq "missing target directory rejected" 1 "$CODE"
run_plant --target
assert_eq "option without value rejected" 1 "$CODE"
run_plant --target "$SKILL"
assert_eq "target = skill source folder rejected" 1 "$CODE"

# ---- path with spaces --------------------------------------------------
mkdir -p "$WORK/my app"
run_plant --target "$WORK/my app" --agent claude
assert_eq "target path with a space" 0 "$CODE"
assert_file "installed under the spaced path" "$WORK/my app/.claude/skills/portable-verification/SKILL.md"

# ---- not a git repo: warns ---------------------------------------------
mkdir -p "$WORK/plain"
run_plant --target "$WORK/plain" --agent claude
assert_contains "warns when target is not a git repo" "$OUT" "not a git repo"

# ---- end to end: NEEDS_REVIEW until committed, then PASS --------------
p=$(new_repo e2e)
run_plant --target "$p" --agent claude
printf 'smoke yes true\n' >> "$p/.verification/checks.txt"
OUT=$(cd "$p" && "$BASH_BIN" .verification/verify.sh 2>&1 </dev/null); CODE=$?
assert_eq "e2e: uncommitted checks -> NEEDS_REVIEW" 2 "$CODE"
commit_all "$p" "plant verification"
OUT=$(cd "$p" && "$BASH_BIN" .verification/verify.sh 2>&1 </dev/null); CODE=$?
assert_eq "e2e: after commit -> PASS" 0 "$CODE"
assert_contains "e2e: status line" "$OUT" "STATUS: PASS"

finish_scenario
