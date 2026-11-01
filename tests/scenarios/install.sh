#!/usr/bin/env bash
# build-release.sh and install.sh: reproducible archives, checksum gate, no change on failure.
. "$(dirname "$0")/../lib.sh"

BUILD="$ROOT/build/build-release.sh"
INSTALL_SRC="$ROOT/install.sh"
VER=$(tr -d '[:space:]' < "$SKILL/VERSION")
AV="portable-verification-skill-v$VER.tar.gz"
AE="portable-eval-skill-v$VER.tar.gz"

# ---- build -------------------------------------------------------------
A="$WORK/dist-a"; B="$WORK/dist-b"
OUT=$("$BASH_BIN" "$BUILD" "$A" 2>&1); CODE=$?
assert_eq "build succeeds" 0 "$CODE"
assert_file "verification archive written" "$A/$AV"
assert_file "eval archive written" "$A/$AE"
assert_file "checksum file written" "$A/$AV.sha256"
sumv=$(sum256 "$A/$AV"); sume=$(sum256 "$A/$AE")
assert_contains "build prints the verification sha256" "$OUT" "$sumv"
assert_contains "build prints the eval sha256" "$OUT" "$sume"
assert_eq "checksum file content" "$sumv  $AV" "$(cat "$A/$AV.sha256")"
if [ "$sumv" != "$sume" ]; then ok "the two archives differ"; else not_ok "the two archives differ"; fi

sleep 1
mkdir -p "$WORK/elsewhere"
(cd "$WORK/elsewhere" && "$BASH_BIN" "$BUILD" "$B" >/dev/null 2>&1)
assert_eq "second verification build (later, other cwd) is byte-identical" "$sumv" "$(sum256 "$B/$AV")"
assert_eq "second eval build is byte-identical" "$sume" "$(sum256 "$B/$AE")"

OUT=$("$BASH_BIN" "$BUILD" "$WORK/dist-one" portable-eval 2>&1); CODE=$?
assert_eq "build of a single skill" 0 "$CODE"
assert_file "single-skill build wrote the eval archive" "$WORK/dist-one/$AE"
assert_no_file "single-skill build did not write the other" "$WORK/dist-one/$AV"
"$BASH_BIN" "$BUILD" "$WORK/dist-x" no-such-skill >/dev/null 2>&1; assert_eq "unknown skill rejected" 1 "$?"

lv=$(tar -tzvf "$A/$AV"); le=$(tar -tzvf "$A/$AE")
assert_contains "verification archive has plant.sh" "$lv" "portable-verification/scripts/plant.sh"
assert_contains "verification archive has VERSION" "$lv" "portable-verification/VERSION"
assert_contains "eval archive has pe.py" "$le" "portable-eval/scripts/pe.py"
assert_contains "eval archive has the schemas" "$le" "portable-eval/schemas/case.schema.json"
assert_contains "eval archive has the contracts" "$le" "portable-eval/docs/contracts.md"
for l in "$lv" "$le"; do
  assert_not_contains "archive does not contain install.sh" "$l" "install.sh"
  assert_not_contains "archive has no macOS metadata files" "$l" "._"
  assert_not_contains "archive has no .git content" "$l" ".git"
  assert_not_contains "archive has no python caches" "$l" "__pycache__"
done

# ---- patched installers ------------------------------------------------
pin() { # OUTFILE VERIFICATION_SHA EVAL_SHA
  sed -e "s/^SHA256_VERIFICATION=\"[^\"]*\"/SHA256_VERIFICATION=\"$2\"/" -e "s/^SHA256_EVAL=\"[^\"]*\"/SHA256_EVAL=\"$3\"/" "$INSTALL_SRC" > "$1"
}
ZERO=$(printf '0%.0s' $(seq 64))
good="$WORK/install-good.sh";      pin "$good" "$sumv" "$sume"
wrong="$WORK/install-wrong.sh";    pin "$wrong" "$sumv" "$ZERO"
unpinned="$WORK/install-un.sh";    pin "$unpinned" UNSET UNSET

run_install() { # SCRIPT [env...] -- args -> OUT/CODE
  local script=$1; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  if [ "${#envs[@]}" -gt 0 ]; then
    OUT=$(env "${envs[@]}" "$BASH_BIN" "$script" "$@" 2>&1 < /dev/null); CODE=$?
  else
    OUT=$("$BASH_BIN" "$script" "$@" 2>&1 < /dev/null); CODE=$?
  fi
}
URL="PV_BASE_URL=file://$A"

t="$WORK/t-unset"; mkdir -p "$t"; before=$(fingerprint "$t")
run_install "$unpinned" "$URL" -- --skill both --target "$t" --agent claude
assert_eq "unpinned install.sh refuses" 1 "$CODE"
assert_contains "refusal explains why" "$OUT" "no pinned sha256"
assert_eq "unpinned refusal leaves target untouched" "$before" "$(fingerprint "$t")"

# ---- success paths -----------------------------------------------------
t="$WORK/t-ver"; mkdir -p "$t"
run_install "$good" "$URL" -- --target "$t" --agent claude --pointer CLAUDE.md
assert_eq "default skill (verification) installs" 0 "$CODE"
assert_contains "install reports sha256 ok" "$OUT" "sha256 ok for portable-verification"
assert_file "verification skill installed" "$t/.claude/skills/portable-verification/SKILL.md"
assert_file "verify.sh installed" "$t/.verification/verify.sh"
assert_no_file "eval not installed by default" "$t/.eval"
assert_contains "install record names the version" "$(cat "$t/.verification/.plant-manifest")" "plant_version=$VER"

t="$WORK/t-eval"; mkdir -p "$t"
run_install "$good" "$URL" -- --skill eval --target "$t" --agent claude
assert_eq "--skill eval installs" 0 "$CODE"
assert_file "eval skill installed" "$t/.claude/skills/portable-eval/SKILL.md"
assert_file "pe.py installed" "$t/.eval/pe.py"
assert_file "schemas installed" "$t/.eval/schemas/evidence.schema.json"
assert_no_file "verification not installed with --skill eval" "$t/.verification"
if python3 -I "$t/.eval/pe.py" plan rule-of-three --bound 0.05 | head -n 1 | grep -qx 59; then ok "installed pe.py runs (rule of three = 59)"; else not_ok "installed pe.py runs"; fi
(cd "$t" && python3 -I .eval/pe.py validate --eval-dir .eval >/dev/null 2>&1); assert_eq "placeholders make validate BLOCKED on purpose" 3 "$?"

t="$WORK/t-both"; mkdir -p "$t"
run_install "$good" "$URL" -- --skill both --target "$t" --agent claude --pointer CLAUDE.md --ci github
assert_eq "--skill both installs" 0 "$CODE"
assert_file "both: verification skill" "$t/.claude/skills/portable-verification/SKILL.md"
assert_file "both: eval skill" "$t/.claude/skills/portable-eval/SKILL.md"
assert_file "both: verification workflow" "$t/.github/workflows/verification.yml"
assert_file "both: eval workflow" "$t/.github/workflows/eval.yml"
assert_eq "both: pointer blocks written once each" "2" "$(grep -c ':start' "$t/CLAUDE.md")"
before=$(fingerprint "$t")
run_install "$good" "$URL" -- --skill both --target "$t" --agent claude --pointer CLAUDE.md --ci github
assert_eq "second install succeeds" 0 "$CODE"
assert_eq "second install changes nothing" "$before" "$(fingerprint "$t")"

t="$WORK/t-dir"; mkdir -p "$t"
run_install "$good" -- --skill both --archive-dir "$A" --target "$t" --agent agents
assert_eq "--archive-dir with both" 0 "$CODE"
assert_file "archive-dir: eval installed" "$t/.agents/skills/portable-eval/SKILL.md"

t="$WORK/t-local"; mkdir -p "$t"
run_install "$good" -- --archive "$A/$AV" --target "$t" --agent agents
assert_eq "--archive with a single skill" 0 "$CODE"
run_install "$good" -- --skill both --archive "$A/$AV" --target "$t"
assert_eq "--archive with both is rejected" 1 "$CODE"

t="$WORK/t-cwd"; mkdir -p "$t"
OUT=$(cd "$t" && "$BASH_BIN" "$good" --archive "$A/$AV" 2>&1 </dev/null); CODE=$?
assert_eq "no plant arguments installs into cwd" 0 "$CODE"
assert_file "cwd install created .verification" "$t/.verification/verify.sh"

t="$WORK/t-pipe"; mkdir -p "$t"
OUT=$(cat "$good" | PV_BASE_URL="file://$A" "$BASH_BIN" -s -- --skill both --target "$t" --agent claude 2>&1); CODE=$?
assert_eq "piped into bash -s works" 0 "$CODE"
assert_file "piped install created the eval skill" "$t/.claude/skills/portable-eval/SKILL.md"

t="$WORK/my project"; mkdir -p "$t"
run_install "$good" "$URL" -- --skill both --target "$t" --agent claude
assert_eq "target path with a space" 0 "$CODE"
assert_file "installed under the spaced path" "$t/.eval/pe.py"

# ---- failures must leave the project untouched, for BOTH skills --------
t="$WORK/t-mismatch"; mkdir -p "$t"; echo keep > "$t/keep.txt"; before=$(fingerprint "$t")
run_install "$wrong" "$URL" -- --skill both --target "$t" --agent claude
assert_eq "checksum mismatch of one skill fails" 1 "$CODE"
assert_contains "mismatch message names the skill" "$OUT" "sha256 mismatch for portable-eval"
assert_eq "mismatch of one skill leaves the target untouched (also for the other skill)" "$before" "$(fingerprint "$t")"

t="$WORK/t-tamper"; mkdir -p "$t"; before=$(fingerprint "$t")
cp "$A/$AV" "$WORK/tampered.tar.gz"; printf 'x' >> "$WORK/tampered.tar.gz"
run_install "$good" -- --archive "$WORK/tampered.tar.gz" --target "$t" --agent claude
assert_eq "tampered archive fails" 1 "$CODE"
assert_eq "tampered archive leaves target untouched" "$before" "$(fingerprint "$t")"

t="$WORK/t-nodl"; mkdir -p "$t"; before=$(fingerprint "$t")
run_install "$good" PV_BASE_URL="file://$WORK/nothing-here" -- --skill both --target "$t" --agent claude
assert_eq "download failure fails" 1 "$CODE"
assert_contains "download failure message" "$OUT" "download failed"
assert_eq "download failure leaves target untouched" "$before" "$(fingerprint "$t")"

t="$WORK/t-missing"; mkdir -p "$t"; mkdir -p "$WORK/half"; cp "$A/$AV" "$WORK/half/"
before=$(fingerprint "$t")
run_install "$good" -- --skill both --archive-dir "$WORK/half" --target "$t" --agent claude
assert_eq "missing archive in --archive-dir fails" 1 "$CODE"
assert_eq "missing archive leaves target untouched" "$before" "$(fingerprint "$t")"

for bad in "--agent bogus" "--ci gitlab" "--nonsense"; do
  t="$WORK/t-bad-$(echo "$bad" | tr -c 'a-z\n' '_')"; mkdir -p "$t"; before=$(fingerprint "$t")
  # shellcheck disable=SC2086
  run_install "$good" "$URL" -- --skill both --target "$t" $bad
  assert_eq "bad plant argument '$bad' fails" 1 "$CODE"
  assert_eq "bad plant argument '$bad' leaves target untouched" "$before" "$(fingerprint "$t")"
done

# Only the eval plant.sh needs git. Without git the eval pre-flight check must fail BEFORE the
# verification skill is written (otherwise we would get a half install).
mkfarm() { # DIR [with-git]
  mkdir -p "$1"
  for tool in bash env tar gzip perl shasum sha256sum cut mktemp cp cat sed grep find mkdir rm diff wc tail dirname \
              basename tr head sort date touch chmod cmp python3 curl uname id seq xargs ls awk readlink rmdir mv ln; do
    p=$(command -v "$tool" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$1/$tool"
  done
  if [ "${2:-}" = with-git ]; then ln -sf "$(command -v git)" "$1/git"; fi
}
mkfarm "$WORK/farm-git" with-git; mkfarm "$WORK/farm-nogit"
t="$WORK/t-farm-ok"; mkdir -p "$t"
OUT=$(env -i HOME="$HOME" PATH="$WORK/farm-git" PV_BASE_URL="file://$A" "$BASH_BIN" "$good" --skill both --target "$t" --agent claude 2>&1 </dev/null); CODE=$?
assert_eq "control: both skills install with git on PATH" 0 "$CODE"
t="$WORK/t-farm-nogit"; mkdir -p "$t"; before=$(fingerprint "$t")
OUT=$(env -i HOME="$HOME" PATH="$WORK/farm-nogit" PV_BASE_URL="file://$A" "$BASH_BIN" "$good" --skill both --target "$t" --agent claude 2>&1 </dev/null); CODE=$?
assert_eq "eval pre-flight failure (no git) fails the install" 1 "$CODE"
assert_contains "pre-flight failure names the reason" "$OUT" "git not found"
assert_eq "no half install: verification was not written either" "$before" "$(fingerprint "$t")"

# A path that exists with the wrong kind must be caught by the pre-flight check, before anything is written
for conflict in ".eval" ".eval/graders" ".claude/skills/portable-eval" ".github/workflows/eval.yml/"; do
  t="$WORK/t-kind-$(echo "$conflict" | tr -c 'a-z\n' '_')"; mkdir -p "$t"
  case "$conflict" in
    */) mkdir -p "$t/${conflict%/}" ;;                       # a directory where a file is expected
    *) mkdir -p "$t/$(dirname "$conflict")"; echo x > "$t/$conflict" ;;   # a file where a directory is expected
  esac
  before=$(fingerprint "$t")
  run_install "$good" "$URL" -- --skill both --target "$t" --agent claude --ci github
  assert_eq "pre-flight rejects a wrong kind of path: $conflict" 1 "$CODE"
  assert_eq "wrong kind of path leaves the target untouched (also verification): $conflict" "$before" "$(fingerprint "$t")"
done

run_install "$good" -- --skill bogus
assert_eq "unknown --skill fails" 1 "$CODE"
run_install "$good" -- --skill
assert_eq "--skill without a value fails" 1 "$CODE"
run_install "$good" -- --archive
assert_eq "--archive without a value fails" 1 "$CODE"

if [ "$(id -u)" -ne 0 ]; then
  t="$WORK/t-ro"; mkdir -p "$t"; chmod a-w "$t"
  run_install "$good" "$URL" -- --skill both --target "$t" --agent claude
  chmod u+w "$t"
  assert_eq "read-only target fails in the pre-flight check" 1 "$CODE"
  assert_eq "read-only target stays empty" "0" "$(find "$t" -mindepth 1 | wc -l | tr -d ' ')"
else
  echo "# note: running as root, the read-only target test was skipped"
fi

t="$WORK/t-user"; mkdir -p "$t/.verification" "$t/.eval"
printf 'mine yes true\n' > "$t/.verification/checks.txt"
printf '{"mine": true}\n' > "$t/.eval/spec.json"
run_install "$good" "$URL" -- --skill both --target "$t" --agent claude --force
assert_eq "install over an existing project" 0 "$CODE"
assert_eq "user checks.txt kept after install --force" "mine yes true" "$(cat "$t/.verification/checks.txt")"
assert_eq "user spec.json kept after install --force" '{"mine": true}' "$(cat "$t/.eval/spec.json")"

finish_scenario
