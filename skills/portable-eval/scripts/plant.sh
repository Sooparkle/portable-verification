#!/usr/bin/env bash
# Plant portable-eval into a project. Safe to rerun: it never overwrites spec.json,
# system-manifest.json, cases, graders or refs, and replaces other files only with --force.
#
# Usage: bash scripts/plant.sh [--target DIR] [--agent NAME]... [--pointer FILE] [--ci github] [--force] [--check]
#   --agent    claude -> .claude/skills/ | agents -> .agents/skills/ | cursor -> .cursor/skills/ | github -> .github/skills/
#              Repeatable. Default: detected from .claude/, .cursor/, .agents/ or AGENTS.md; else agents.
#   --pointer  append a short marked block to FILE (e.g. AGENTS.md or CLAUDE.md), once
#   --ci       github: add .github/workflows/eval.yml (trusted gate) if missing
#   --force    replace a differing skill folder, .eval/pe.py or .eval/schemas/*
#   --check    validate arguments and prerequisites, write nothing
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
NAME=portable-eval
target=.; agents=""; pointer=""; ci=""; force=0; check=0

die() { echo "plant: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --target) [ $# -ge 2 ] || die "--target needs a value"; target=$2; shift 2 ;;
    --agent) [ $# -ge 2 ] || die "--agent needs a value"; agents="$agents $2"; shift 2 ;;
    --pointer) [ $# -ge 2 ] || die "--pointer needs a value"; pointer=$2; shift 2 ;;
    --ci) [ $# -ge 2 ] || die "--ci needs a value"; ci=$2; shift 2 ;;
    --force) force=1; shift ;;
    --check) check=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -d "$target" ] || die "target directory not found: $target"
target=$(cd "$target" && pwd)
[ "$target" != "$SRC" ] || die "target is the skill source folder; pass --target <project>"
[ -w "$target" ] || die "target directory is not writable: $target"
[ -f "$SRC/SKILL.md" ] && [ -f "$SRC/scripts/pe.py" ] && [ -f "$SRC/VERSION" ] || die "incomplete skill folder: $SRC"
command -v python3 >/dev/null 2>&1 || die "python3 not found (portable-eval needs Python 3.9 or newer)"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
  || die "python3 is older than 3.9 ($(python3 --version 2>&1))"
command -v git >/dev/null 2>&1 || die "git not found (trusted mode needs it)"
git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || echo "plant: warning: $target is not a git repo; trusted mode (--trusted-ref) will not work"

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
case "$ci" in ""|github) ;; *) die "unknown --ci value: $ci (supported: github)" ;; esac
if [ -n "$pointer" ]; then
  pf="$target/$pointer"
  { [ -e "$pf" ] && [ -w "$pf" ]; } || { [ ! -e "$pf" ] && [ -w "$(dirname "$pf")" ]; } || die "pointer file is not writable: $pointer"
fi

if [ "$check" = 1 ]; then echo "plant: check ok ($NAME, target $target)"; exit 0; fi

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo unavailable; fi
}

stage_skill() { # DEST
  mkdir -p "$1"
  cp "$SRC/SKILL.md" "$SRC/VERSION" "$1/"
  cp -R "$SRC/docs" "$SRC/references" "$SRC/schemas" "$SRC/scripts" "$1/"
}

echo "plant: skill folder"
for d in $skill_dirs; do
  dest="$target/$d/$NAME"
  verb=created
  if [ -e "$dest" ] && [ "$force" = 1 ]; then rm -rf "$dest"; verb=replaced; fi
  if [ ! -e "$dest" ]; then
    stage_skill "$dest"; printf '  %-8s %s\n' "$verb" "$d/$NAME"
  else
    tmp=$(mktemp -d); stage_skill "$tmp/$NAME"
    if diff -rq "$tmp/$NAME" "$dest" >/dev/null 2>&1; then echo "  same     $d/$NAME"
    else echo "  skipped  $d/$NAME (differs; rerun with --force to replace)"; fi
    rm -rf "$tmp"
  fi
done

echo "plant: project files"
E="$target/.eval"; mkdir -p "$E/cases" "$E/graders" "$E/refs" "$E/schemas"
# copy_file SRC DEST: create, keep if identical, replace only with --force
copy_file() {
  if [ ! -e "$2" ]; then cp "$1" "$2"; echo "  created  ${2#$target/}"
  elif cmp -s "$1" "$2"; then echo "  same     ${2#$target/}"
  elif [ "$force" = 1 ]; then cp "$1" "$2"; echo "  replaced ${2#$target/}"
  else echo "  skipped  ${2#$target/} (differs; rerun with --force to replace)"; fi
}
copy_file "$SRC/scripts/pe.py" "$E/pe.py"
chmod +x "$E/pe.py" 2>/dev/null || true
for f in "$SRC"/schemas/*.json; do copy_file "$f" "$E/schemas/$(basename "$f")"; done
keep_or_create() { # SRC DEST
  if [ -e "$2" ]; then echo "  kept     ${2#$target/}"; else cp "$1" "$2"; echo "  created  ${2#$target/}"; fi
}
keep_or_create "$SRC/references/spec.template.json" "$E/spec.json"
keep_or_create "$SRC/references/system-manifest.template.json" "$E/system-manifest.json"
for k in cases graders refs; do [ -e "$E/$k/.gitkeep" ] || : > "$E/$k/.gitkeep"; done

{
  echo "# portable-eval install record (informational, not an integrity guarantee)"
  echo "plant_version=$(tr -d '[:space:]' < "$SRC/VERSION")"
  echo "source_commit=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "sha256  .eval/pe.py  $(hash_file "$E/pe.py")"
  for f in "$E"/schemas/*.json; do echo "sha256  .eval/schemas/$(basename "$f")  $(hash_file "$f")"; done
} > "$E/.plant-manifest"
echo "  wrote    .eval/.plant-manifest"

gi="$target/.gitignore"
if grep -qxF ".eval/runs/" "$gi" 2>/dev/null; then echo "  kept     .gitignore entry"
else
  if [ -s "$gi" ] && [ -n "$(tail -c 1 "$gi")" ]; then echo >> "$gi"; fi
  echo ".eval/runs/" >> "$gi"; echo "  added    .eval/runs/ to .gitignore"
fi

if [ -n "$pointer" ]; then
  pf="$target/$pointer"
  if grep -qs "portable-eval:start" "$pf"; then echo "  kept     pointer in $pointer"
  else
    if [ -s "$pf" ] && [ -n "$(tail -c 1 "$pf")" ]; then echo >> "$pf"; fi
    cat >> "$pf" <<'EOF'

<!-- portable-eval:start -->
## Agent evaluation gates
- If you change a prompt, model, tool or harness covered by `.eval/`, use the portable-eval skill and run `python3 -I .eval/pe.py gate ...`.
- Report the MODE, STATUS and EVIDENCE lines exactly as printed. A `local (unofficial)` result is not an official verdict.
- Never edit `.eval/spec.json`, `cases/`, `graders/`, `refs/`, `schemas/` or `pe.py` to make a gate pass.
<!-- portable-eval:end -->
EOF
    echo "  added    pointer block to $pointer"
  fi
fi

if [ "$ci" = github ]; then
  wf="$target/.github/workflows/eval.yml"
  if [ -e "$wf" ]; then echo "  kept     .github/workflows/eval.yml"
  else mkdir -p "$(dirname "$wf")"; cp "$SRC/references/ci-eval-trusted.yml" "$wf"; echo "  created  .github/workflows/eval.yml"; fi
fi

cat <<EOF
plant: done. Next:
  1. Fill .eval/spec.json and .eval/system-manifest.json (the REPLACE placeholders make the gate BLOCKED on purpose).
  2. Write graders under .eval/graders/ and cases under .eval/cases/ (see references/case.template.json).
  3. Write your adapter (it is part of the system under test, not an evaluation asset) and run:
       python3 -I .eval/pe.py validate --eval-dir .eval
  4. Official results need CI that runs pe.py from the base branch: see references/ci-eval-trusted.yml,
     and protect .eval/ and .github/ with CODEOWNERS + required review (references/CODEOWNERS.example).
  Update later: run plant.sh from a newer release with --force. spec.json, system-manifest.json, cases, graders and refs are kept.
EOF
