#!/usr/bin/env bash
# Plant portable-verification into a project. Safe to rerun: it never overwrites
# checks.txt or feature-map.md, and replaces other files only with --force.
#
# Usage: bash scripts/plant.sh [--target DIR] [--agent NAME]... [--pointer FILE] [--ci github] [--force]
#   --agent   claude  -> .claude/skills/   (Claude Code)
#             agents  -> .agents/skills/   (Codex; also read by GitHub Copilot)
#             cursor  -> .cursor/skills/   (Cursor)
#             github  -> .github/skills/   (GitHub Copilot)
#             Repeatable. Default: detected from .claude/, .cursor/, .agents/ or AGENTS.md; else agents.
#   --pointer append a short marked block to FILE (e.g. AGENTS.md or CLAUDE.md), once
#   --ci      github: add .github/workflows/verification.yml if missing
#   --force   replace a differing skill folder or .verification/verify.sh
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
NAME=portable-verification
target=.; agents=""; pointer=""; ci=""; force=0

die() { echo "plant: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --target) [ $# -ge 2 ] || die "--target needs a value"; target=$2; shift 2 ;;
    --agent) [ $# -ge 2 ] || die "--agent needs a value"; agents="$agents $2"; shift 2 ;;
    --pointer) [ $# -ge 2 ] || die "--pointer needs a value"; pointer=$2; shift 2 ;;
    --ci) [ $# -ge 2 ] || die "--ci needs a value"; ci=$2; shift 2 ;;
    --force) force=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -d "$target" ] || die "target directory not found: $target"
target=$(cd "$target" && pwd)
[ "$target" != "$SRC" ] || die "target is the skill source folder; pass --target <project>"
[ -f "$SRC/SKILL.md" ] && [ -f "$SRC/scripts/verify.sh" ] || die "incomplete skill folder: $SRC"
git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || echo "plant: warning: $target is not a git repo; verify.sh will report NEEDS_REVIEW (change set unknown)"

if [ -z "$agents" ]; then
  [ -d "$target/.claude" ] && agents="$agents claude"
  [ -d "$target/.cursor" ] && agents="$agents cursor"
  { [ -d "$target/.agents" ] || [ -f "$target/AGENTS.md" ]; } && agents="$agents agents"
  [ -n "$agents" ] || agents=" agents"
  echo "plant: agents detected:$agents (override with --agent)"
fi

skill_dirs=""
for a in $agents; do
  case "$a" in
    claude) d=.claude/skills ;; agents|codex) d=.agents/skills ;;
    cursor) d=.cursor/skills ;; github|copilot) d=.github/skills ;;
    *) die "unknown agent: $a" ;;
  esac
  case " $skill_dirs " in *" $d "*) ;; *) skill_dirs="$skill_dirs $d" ;; esac
done
[ "$(echo $skill_dirs | wc -w)" -gt 1 ] && echo "plant: note: a tool that reads several of these folders may list the skill twice"

# copy_tree SRC DEST: create, keep if identical, replace only with --force
copy_tree() {
  if [ ! -e "$2" ]; then
    mkdir -p "$(dirname "$2")"; cp -R "$1" "$2"; echo "  created  ${2#$target/}"
  elif diff -rq "$1" "$2" >/dev/null 2>&1; then echo "  same     ${2#$target/}"
  elif [ "$force" = 1 ]; then rm -rf "$2"; cp -R "$1" "$2"; echo "  replaced ${2#$target/}"
  else echo "  skipped  ${2#$target/} (differs; rerun with --force to replace)"; fi
}

echo "plant: skill folder"
for d in $skill_dirs; do
  dest="$target/$d/$NAME"
  if [ -e "$dest" ] && [ "$force" = 1 ]; then rm -rf "$dest"; fi
  if [ ! -e "$dest" ]; then
    mkdir -p "$dest"
    cp "$SRC/SKILL.md" "$SRC/SOURCES.md" "$dest/"
    cp -R "$SRC/references" "$SRC/scripts" "$dest/"
    echo "  created  $d/$NAME"
  else
    tmp=$(mktemp -d); mkdir -p "$tmp/$NAME"
    cp "$SRC/SKILL.md" "$SRC/SOURCES.md" "$tmp/$NAME/"; cp -R "$SRC/references" "$SRC/scripts" "$tmp/$NAME/"
    if diff -rq "$tmp/$NAME" "$dest" >/dev/null 2>&1; then echo "  same     $d/$NAME"
    else echo "  skipped  $d/$NAME (differs; rerun with --force to replace)"; fi
    rm -rf "$tmp"
  fi
done

echo "plant: project files"
V="$target/.verification"; mkdir -p "$V"
copy_tree "$SRC/scripts/verify.sh" "$V/verify.sh"; chmod +x "$V/verify.sh" 2>/dev/null || true

if [ -e "$V/feature-map.md" ]; then echo "  kept     .verification/feature-map.md"
else cp "$SRC/references/feature-map.template.md" "$V/feature-map.md"; echo "  created  .verification/feature-map.md"; fi

suggest() { printf '#%s %s %s\n' "$1" "$2" "$3"; }
has_script() { grep -Eq "\"$1\"[[:space:]]*:" "$target/package.json" 2>/dev/null; }
if [ -e "$V/checks.txt" ]; then echo "  kept     .verification/checks.txt"
else
  {
    echo "# portable-verification checks: one per line -> id required command"
    echo "#   id: letters, digits, . _ -    required: yes | no    command: rest of the line, run from the repo root"
    echo "# Fields are separated by spaces or tabs. Keep secrets in environment variables, never here."
    echo "# verify.sh reports NOT RUN while no line is enabled and BLOCKED while no enabled line is required=yes."
    echo "# Suggested lines were detected from project files. Delete the leading # to enable one."
    echo "# Changing this file makes verify.sh report NEEDS_REVIEW until a human reviews it."
    echo
    if [ -f "$target/package.json" ]; then
      pm=npm
      [ -f "$target/pnpm-lock.yaml" ] && pm=pnpm
      [ -f "$target/yarn.lock" ] && pm=yarn
      { [ -f "$target/bun.lockb" ] || [ -f "$target/bun.lock" ]; } && pm=bun
      run="$pm run"
      has_script test && suggest unit yes "$run test"
      has_script typecheck && suggest typecheck yes "$run typecheck"
      has_script build && suggest build yes "$run build"
      has_script lint && suggest lint no "$run lint"
      has_script "test:e2e" && suggest e2e yes "$run test:e2e"
    fi
    if [ -f "$target/pytest.ini" ] || grep -qs pytest "$target/pyproject.toml" "$target/setup.cfg" "$target/tox.ini" "$target"/requirements*.txt; then
      suggest unit-py yes "python -m pytest -q"
    fi
    [ -f "$target/go.mod" ] && { suggest unit-go yes "go test ./..."; suggest vet no "go vet ./..."; }
    [ -f "$target/Cargo.toml" ] && suggest unit-rs yes "cargo test"
    [ -f "$target/gradlew" ] && suggest unit-gradle yes "./gradlew test"
    [ -f "$target/pom.xml" ] && suggest unit-mvn yes "mvn -q test"
    [ -f "$target/pubspec.yaml" ] && suggest unit-flutter yes "flutter test"
    grep -Eqs '^test:' "$target/Makefile" && suggest make-test yes "make test"
    echo "#smoke yes curl -fsS http://localhost:3000/health   # example only"
  } > "$V/checks.txt"
  echo "  created  .verification/checks.txt"
fi

gi="$target/.gitignore"
if grep -qxF ".verification/evidence/" "$gi" 2>/dev/null; then echo "  kept     .gitignore entry"
else
  if [ -s "$gi" ] && [ -n "$(tail -c 1 "$gi")" ]; then echo >> "$gi"; fi
  echo ".verification/evidence/" >> "$gi"; echo "  added    .verification/evidence/ to .gitignore"
fi

if [ -n "$pointer" ]; then
  pf="$target/$pointer"
  if grep -qs "portable-verification:start" "$pf"; then echo "  kept     pointer in $pointer"
  else
    if [ -s "$pf" ] && [ -n "$(tail -c 1 "$pf")" ]; then echo >> "$pf"; fi
    cat >> "$pf" <<'EOF'

<!-- portable-verification:start -->
## Verification
- Before reporting a feature or bug fix as done, use the portable-verification skill.
- Run `bash .verification/verify.sh` and report its STATUS line and evidence directory exactly as printed.
- If you change tests or `.verification/checks.txt`, say why in the report. Never set TESTS_REVIEWED.
<!-- portable-verification:end -->
EOF
    echo "  added    pointer block to $pointer"
  fi
fi

case "$ci" in
  "") ;;
  github)
    wf="$target/.github/workflows/verification.yml"
    if [ -e "$wf" ]; then echo "  kept     .github/workflows/verification.yml"
    else mkdir -p "$(dirname "$wf")"; cp "$SRC/references/ci-github-actions.yml" "$wf"; echo "  created  .github/workflows/verification.yml"; fi ;;
  *) die "unknown --ci value: $ci (supported: github)" ;;
esac

cat <<EOF
plant: done. Next:
  1. Edit .verification/checks.txt: enable at least one required=yes check.
  2. Fill .verification/feature-map.md for the 3-5 features users depend on most.
  3. Run: bash .verification/verify.sh   (first run reports NEEDS_REVIEW until the new files are committed)
  4. Commit the skill folder, .verification/ (evidence is ignored), and .gitignore.
EOF
