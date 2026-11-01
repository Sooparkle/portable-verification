#!/usr/bin/env bash
# build-release.sh and install.sh: reproducible archive, checksum gate, no change on failure.
. "$(dirname "$0")/../lib.sh"

BUILD="$ROOT/build/build-release.sh"
INSTALL_SRC="$ROOT/install.sh"

# ---- build -------------------------------------------------------------
A="$WORK/dist-a"; B="$WORK/dist-b"
OUT=$("$BASH_BIN" "$BUILD" "$A" 2>&1); CODE=$?
assert_eq "build succeeds" 0 "$CODE"
archive="$A/portable-verification-skill-v0.1.0.tar.gz"
assert_file "archive written" "$archive"
assert_file "checksum file written" "$archive.sha256"
sum=$(sum256 "$archive")
assert_contains "build prints the same sha256" "$OUT" "$sum"
assert_eq "checksum file content" "$sum  portable-verification-skill-v0.1.0.tar.gz" "$(cat "$archive.sha256")"

sleep 1
mkdir -p "$WORK/elsewhere"
(cd "$WORK/elsewhere" && "$BASH_BIN" "$BUILD" "$B" >/dev/null 2>&1)
assert_eq "second build (later, other cwd) is byte-identical" "$sum" "$(sum256 "$B/portable-verification-skill-v0.1.0.tar.gz")"

listing=$(tar -tzvf "$archive")
assert_contains "archive has SKILL.md" "$listing" "portable-verification/SKILL.md"
assert_contains "archive has VERSION" "$listing" "portable-verification/VERSION"
assert_contains "archive has plant.sh" "$listing" "portable-verification/scripts/plant.sh"
assert_not_contains "archive does not contain install.sh" "$listing" "install.sh"
assert_not_contains "archive has no macOS metadata files" "$listing" "._"
assert_not_contains "archive has no .git content" "$listing" ".git"

# ---- patched installers ------------------------------------------------
good="$WORK/install-good.sh"
sed "s/^ARCHIVE_SHA256=\"[^\"]*\"/ARCHIVE_SHA256=\"$sum\"/" "$INSTALL_SRC" > "$good"
wrong="$WORK/install-wrong.sh"
sed "s/^ARCHIVE_SHA256=\"[^\"]*\"/ARCHIVE_SHA256=\"$(printf '0%.0s' $(seq 64))\"/" "$INSTALL_SRC" > "$wrong"
unpinned="$WORK/install-unpinned.sh"
sed 's/^ARCHIVE_SHA256="[^"]*"/ARCHIVE_SHA256="UNSET"/' "$INSTALL_SRC" > "$unpinned"

# run_install SCRIPT [env...] -- args -> OUT/CODE ; env goes before "--"
run_install() {
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

# a copy without a pinned hash (development checkout) must refuse
t="$WORK/t-unset"; mkdir -p "$t"; before=$(fingerprint "$t")
run_install "$unpinned" PV_BASE_URL="file://$A" -- --target "$t" --agent claude
assert_eq "unpinned install.sh refuses" 1 "$CODE"
assert_contains "refusal explains why" "$OUT" "no pinned sha256"
assert_eq "unpinned refusal leaves target untouched" "$before" "$(fingerprint "$t")"

# success through the download path (file:// stands in for the release URL)
t="$WORK/t-ok"; mkdir -p "$t"
run_install "$good" PV_BASE_URL="file://$A" -- --target "$t" --agent claude --pointer CLAUDE.md
assert_eq "install via download succeeds" 0 "$CODE"
assert_contains "install reports sha256 ok" "$OUT" "sha256 ok"
assert_file "skill installed" "$t/.claude/skills/portable-verification/SKILL.md"
assert_file "verify.sh installed" "$t/.verification/verify.sh"
assert_contains "record names the archive version" "$(cat "$t/.verification/.plant-manifest")" "plant_version=0.1.0"
before=$(fingerprint "$t")
run_install "$good" PV_BASE_URL="file://$A" -- --target "$t" --agent claude --pointer CLAUDE.md
assert_eq "second install succeeds" 0 "$CODE"
assert_eq "second install changes nothing" "$before" "$(fingerprint "$t")"

# local archive path
t="$WORK/t-local"; mkdir -p "$t"
run_install "$good" -- --archive "$archive" --target "$t" --agent agents
assert_eq "install from --archive succeeds" 0 "$CODE"
assert_file "skill installed from local archive" "$t/.agents/skills/portable-verification/SKILL.md"

# no plant args: installs into the current directory
t="$WORK/t-cwd"; mkdir -p "$t"
OUT=$(cd "$t" && "$BASH_BIN" "$good" --archive "$archive" 2>&1 </dev/null); CODE=$?
assert_eq "no plant arguments installs into cwd" 0 "$CODE"
assert_file "cwd install created .verification" "$t/.verification/verify.sh"

# piped from stdin like `curl | bash -s --`
t="$WORK/t-pipe"; mkdir -p "$t"
OUT=$(cat "$good" | PV_BASE_URL="file://$A" "$BASH_BIN" -s -- --target "$t" --agent claude 2>&1); CODE=$?
assert_eq "piped into bash -s works" 0 "$CODE"
assert_file "piped install created the skill" "$t/.claude/skills/portable-verification/SKILL.md"

# spaces in the target path
t="$WORK/my project"; mkdir -p "$t"
run_install "$good" PV_BASE_URL="file://$A" -- --target "$t" --agent claude
assert_eq "target path with a space" 0 "$CODE"
assert_file "installed under the spaced path" "$t/.claude/skills/portable-verification/SKILL.md"

# ---- failures must leave the project untouched ------------------------
t="$WORK/t-mismatch"; mkdir -p "$t"; echo keep > "$t/keep.txt"; before=$(fingerprint "$t")
run_install "$wrong" PV_BASE_URL="file://$A" -- --target "$t" --agent claude
assert_eq "checksum mismatch fails" 1 "$CODE"
assert_contains "mismatch message" "$OUT" "sha256 mismatch"
assert_eq "checksum mismatch leaves target untouched" "$before" "$(fingerprint "$t")"

t="$WORK/t-tamper"; mkdir -p "$t"; before=$(fingerprint "$t")
cp "$archive" "$WORK/tampered.tar.gz"; printf 'x' >> "$WORK/tampered.tar.gz"
run_install "$good" -- --archive "$WORK/tampered.tar.gz" --target "$t" --agent claude
assert_eq "tampered archive fails" 1 "$CODE"
assert_eq "tampered archive leaves target untouched" "$before" "$(fingerprint "$t")"

t="$WORK/t-nodl"; mkdir -p "$t"; before=$(fingerprint "$t")
run_install "$good" PV_BASE_URL="file://$WORK/nothing-here" -- --target "$t" --agent claude
assert_eq "download failure fails" 1 "$CODE"
assert_contains "download failure message" "$OUT" "download failed"
assert_eq "download failure leaves target untouched" "$before" "$(fingerprint "$t")"

t="$WORK/t-noarch"; mkdir -p "$t"
run_install "$good" -- --archive "$WORK/missing.tar.gz" --target "$t"
assert_eq "missing --archive file fails" 1 "$CODE"

t="$WORK/t-badarg"; mkdir -p "$t"; before=$(fingerprint "$t")
run_install "$good" -- --archive "$archive" --target "$t" --agent bogus
assert_eq "bad plant argument fails" 1 "$CODE"
assert_eq "bad plant argument leaves target untouched" "$before" "$(fingerprint "$t")"

run_install "$good" -- --archive
assert_eq "--archive without a value fails" 1 "$CODE"

# existing user files survive a (re)install
t="$WORK/t-user"; mkdir -p "$t/.verification"
printf 'mine yes true\n' > "$t/.verification/checks.txt"
run_install "$good" -- --archive "$archive" --target "$t" --agent claude --force
assert_eq "install over existing project" 0 "$CODE"
assert_eq "user checks.txt kept after install --force" "mine yes true" "$(cat "$t/.verification/checks.txt")"

finish_scenario
