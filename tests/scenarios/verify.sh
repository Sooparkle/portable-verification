#!/usr/bin/env bash
# verify.sh: statuses, bypass attempts, parsing, redaction, stdin, interruption.
. "$(dirname "$0")/../lib.sh"

# ---- the five statuses -------------------------------------------------
d=$(repo_with_checks pass 'ok yes true')
run_verify "$d"
assert_eq "PASS exit code" 0 "$CODE"
assert_contains "PASS status line" "$OUT" "STATUS: PASS"
assert_file "evidence LATEST pointer written" "$d/.verification/evidence/LATEST"
assert_file "summary.tsv written" "$(latest_dir "$d")/summary.tsv"
assert_eq "status file says PASS" "PASS" "$(cat "$(latest_dir "$d")/status")"

d=$(repo_with_checks fail $'good yes true\nbad yes false')
run_verify "$d"
assert_eq "FAIL exit code" 1 "$CODE"
assert_contains "FAIL status line" "$OUT" "STATUS: FAIL"

d=$(repo_with_checks optfail $'good yes true\nlint no false')
run_verify "$d"
assert_eq "optional failure does not fail the run" 0 "$CODE"
assert_contains "optional failure is reported" "$OUT" "optional failures: 1"

d=$(new_repo blocked-nofile)
run_verify "$d"
assert_eq "BLOCKED when checks file is missing" 3 "$CODE"
assert_contains "BLOCKED status line" "$OUT" "STATUS: BLOCKED"

d=$(repo_with_checks blocked-norequired 'a no true')
run_verify "$d"
assert_eq "BLOCKED when no check is required" 3 "$CODE"

d=$(repo_with_checks notrun $'# only comments\n\n   \n# more')
run_verify "$d"
assert_eq "NOT RUN when nothing is declared" 4 "$CODE"
assert_contains "NOT RUN status line" "$OUT" "STATUS: NOT RUN"

# ---- review gate -------------------------------------------------------
d=$(repo_with_checks review-checks 'ok yes true')
printf 'extra no true\n' >> "$d/.verification/checks.txt"
run_verify "$d"
assert_eq "NEEDS_REVIEW when checks.txt changed" 2 "$CODE"
assert_contains "flagged file listed" "$(cat "$(latest_dir "$d")/flagged-files.txt")" ".verification/checks.txt"

d=$(repo_with_checks review-test 'ok yes true')
mkdir -p "$d/tests"; echo 'x' > "$d/tests/foo.test.js"
run_verify "$d"
assert_eq "NEEDS_REVIEW when a test file is added" 2 "$CODE"

d=$(repo_with_checks review-config 'ok yes true')
echo 'module.exports={}' > "$d/jest.config.js"
run_verify "$d"
assert_eq "NEEDS_REVIEW when test config changed" 2 "$CODE"

d=$(repo_with_checks review-verifysh 'ok yes true')
mkdir -p "$d/.verification"; echo '# edited' > "$d/.verification/verify.sh"
run_verify "$d"
assert_eq "NEEDS_REVIEW when verify.sh itself is added/changed" 2 "$CODE"

# weakening: flip a failing required check to optional -> must not be PASS
d=$(repo_with_checks weaken $'a yes true\nb yes false')
sed -i.bak 's/^b yes/b no/' "$d/.verification/checks.txt"; rm -f "$d/.verification/checks.txt.bak"
run_verify "$d"
assert_eq "weakening required->no is NEEDS_REVIEW, not PASS" 2 "$CODE"

d=$(repo_with_checks reviewed 'ok yes true')
echo 'x' > "$d/jest.config.js"
run_verify "$d" TESTS_REVIEWED=1
assert_eq "TESTS_REVIEWED=1 clears the review gate" 0 "$CODE"
assert_contains "review override is stated in the status" "$OUT" "TESTS_REVIEWED=1"

# invariant: TESTS_REVIEWED never turns a real failure into PASS
d=$(repo_with_checks reviewed-fail 'bad yes false')
echo 'x' > "$d/jest.config.js"
run_verify "$d" TESTS_REVIEWED=1
assert_eq "TESTS_REVIEWED=1 + failing required check is still FAIL" 1 "$CODE"

# branch workflow: committed test change on a feature branch
d=$(repo_with_checks branch 'ok yes true')
(cd "$d" && git checkout -q -b feat && mkdir -p tests && echo x > tests/a.test.js && git add -A && git commit -q -m t)
run_verify "$d"
assert_eq "committed test change vs main is NEEDS_REVIEW" 2 "$CODE"
run_verify "$d" BASE_REF=main
assert_eq "explicit BASE_REF works" 2 "$CODE"
d=$(repo_with_checks branch-clean 'ok yes true')
(cd "$d" && git checkout -q -b feat && echo y > src.txt && git add -A && git commit -q -m s)
run_verify "$d"
assert_eq "non-test change on a branch is PASS" 0 "$CODE"

# change set cannot be determined -> NEEDS_REVIEW, never silent PASS
mkdir -p "$WORK/nogit/.verification"; echo 'ok yes true' > "$WORK/nogit/.verification/checks.txt"
run_verify "$WORK/nogit"
assert_eq "not a git repo is NEEDS_REVIEW" 2 "$CODE"
assert_contains "UNKNOWN is reported" "$OUT" "UNKNOWN"

mkdir -p "$WORK/nocommit/.verification"; (cd "$WORK/nocommit" && git init -q -b main)
echo 'ok yes true' > "$WORK/nocommit/.verification/checks.txt"
run_verify "$WORK/nocommit"
assert_eq "repo without commits is NEEDS_REVIEW" 2 "$CODE"

# ---- parsing -----------------------------------------------------------
d=$(repo_with_checks tabs "$(printf 'a\tyes\ttrue\nb\tno\ttrue')")
run_verify "$d"
assert_eq "tab separated fields" 0 "$CODE"

d=$(repo_with_checks crlf "$(printf 'a yes true\r\nb yes true\r')")
run_verify "$d"
assert_eq "CRLF line endings" 0 "$CODE"

d=$(repo_with_checks quoting 'q yes echo "a b" | grep -q "a b"')
run_verify "$d"
assert_eq "command with quotes and a pipe" 0 "$CODE"

d=$(repo_with_checks dup $'a yes true\na yes true')
run_verify "$d"
assert_eq "duplicate id is BLOCKED" 3 "$CODE"

d=$(repo_with_checks badreq $'a maybe true')
run_verify "$d"
assert_eq "invalid required field is BLOCKED" 3 "$CODE"

d=$(repo_with_checks badid $'bad/id yes true')
run_verify "$d"
assert_eq "invalid id is BLOCKED" 3 "$CODE"

d=$(repo_with_checks nocmd $'a yes')
run_verify "$d"
assert_eq "missing command is BLOCKED" 3 "$CODE"

# format errors are all found before anything runs
d=$(repo_with_checks noexec $'first yes touch ran-marker\nsecond maybe true')
run_verify "$d"
assert_eq "invalid line blocks the whole run" 3 "$CODE"
assert_no_file "no command ran when the file is invalid" "$d/ran-marker"

# checks file passed as an argument (relative to cwd and absolute)
d=$(repo_with_checks argfile 'ok yes true')
printf 'alt yes true\n' > "$d/alt.txt"; commit_all "$d" alt
run_verify "$d" ; OUT=$(cd "$d" && "$BASH_BIN" "$VERIFY" alt.txt 2>&1 </dev/null); CODE=$?
assert_eq "relative checks file argument" 0 "$CODE"
OUT=$(cd "$d" && "$BASH_BIN" "$VERIFY" "$d/alt.txt" 2>&1 </dev/null); CODE=$?
assert_eq "absolute checks file argument" 0 "$CODE"

# path with a space
d=$(repo_with_checks "my repo" 'ok yes true')
run_verify "$d"
assert_eq "repository path containing a space" 0 "$CODE"

# commands run from the repository root even when invoked from a subdirectory
d=$(repo_with_checks rootcwd 'where yes test -f README.md')
mkdir -p "$d/sub"
OUT=$(cd "$d/sub" && "$BASH_BIN" "$VERIFY" 2>&1 </dev/null); CODE=$?
assert_eq "checks run from the repository root" 0 "$CODE"

# ---- redaction ---------------------------------------------------------
d=$(repo_with_checks redact 'secret yes echo "t=$MY_API_TOKEN"; echo "Authorization: Bearer abcdefghijkl1234"; echo "Set-Cookie: sid=cookieval99"; echo "Bearer zzzzzzzz9999"')
run_verify "$d" MY_API_TOKEN=supersecretvalue123
log=$(cat "$(latest_dir "$d")/secret.log")
assert_eq "redaction run passes" 0 "$CODE"
assert_not_contains "env secret value removed from log" "$log" "supersecretvalue123"
assert_not_contains "Authorization value removed" "$log" "abcdefghijkl1234"
assert_not_contains "Cookie value removed" "$log" "cookieval99"
assert_not_contains "Bearer token removed" "$log" "zzzzzzzz9999"
assert_contains "placeholder present" "$log" "<REDACTED>"

# ---- stdin is not given to checks -------------------------------------
d=$(repo_with_checks stdin 'eat yes cat > /dev/null')
mkfifo "$WORK/fifo"; exec 7<>"$WORK/fifo"
( cd "$d" && "$BASH_BIN" "$VERIFY" <&7 > "$WORK/stdin.out" 2>&1 ) &
pid=$!
n=0; while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 8 ]; do sleep 1; n=$((n + 1)); done
if kill -0 "$pid" 2>/dev/null; then
  not_ok "checks do not read the caller's stdin" "run still blocked after 8s"
  pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
else ok "checks do not read the caller's stdin"; fi
wait "$pid" 2>/dev/null
exec 7<&-

# ---- interruption -> NOT RUN ------------------------------------------
d=$(repo_with_checks interrupt 'slow yes sleep 2')
pushd "$d" >/dev/null
"$BASH_BIN" "$VERIFY" > "$WORK/int.out" 2>&1 < /dev/null &
pid=$!
popd >/dev/null
sleep 1; kill -TERM "$pid" 2>/dev/null
wait "$pid"; code=$?
assert_eq "SIGTERM ends with NOT RUN (exit 4)" 4 "$code"
assert_contains "interrupted status line" "$(cat "$WORK/int.out")" "interrupted"

# ---- timeout -----------------------------------------------------------
d=$(repo_with_checks timeout 'slow yes sleep 5')
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  run_verify "$d" CHECK_TIMEOUT=1
  assert_eq "timed out required check is FAIL" 1 "$CODE"
  assert_contains "timeout recorded in summary" "$(cat "$(latest_dir "$d")/summary.tsv")" "timeout"
  echo 'x' > "$d/jest.config.js"
  run_verify "$d" CHECK_TIMEOUT=1 TESTS_REVIEWED=1
  assert_eq "TESTS_REVIEWED=1 + timeout is still FAIL" 1 "$CODE"
else
  run_verify "$d" CHECK_TIMEOUT=1
  assert_eq "CHECK_TIMEOUT without timeout/gtimeout is BLOCKED" 3 "$CODE"
  assert_contains "BLOCKED names the missing tool" "$OUT" "neither timeout nor gtimeout"
  echo "# note: timeout/gtimeout not installed here, so the real timeout path was NOT exercised"
fi

# Exercise the timeout handling with a stand-in `timeout` (exit 124 on expiry, like GNU timeout).
# This tests verify.sh's reaction to exit 124, not the real timeout binary.
mkdir -p "$WORK/shim"
cat > "$WORK/shim/timeout" <<'PERL'
#!/usr/bin/perl
my $secs = shift @ARGV;
my $pid = fork();
if ($pid == 0) { exec @ARGV or exit 127 }
$SIG{ALRM} = sub { kill 'TERM', $pid; waitpid($pid, 0); exit 124 };
alarm $secs; waitpid($pid, 0); alarm 0; exit($? >> 8);
PERL
chmod +x "$WORK/shim/timeout"
d=$(repo_with_checks timeout-shim 'slow yes sleep 3')
run_verify "$d" PATH="$WORK/shim:$PATH" CHECK_TIMEOUT=1
assert_eq "timeout (shim, exit 124) on a required check is FAIL" 1 "$CODE"
assert_contains "timeout (shim) recorded in summary" "$(cat "$(latest_dir "$d")/summary.tsv")" "timeout"
echo 'x' > "$d/jest.config.js"
run_verify "$d" PATH="$WORK/shim:$PATH" CHECK_TIMEOUT=1 TESTS_REVIEWED=1
assert_eq "TESTS_REVIEWED=1 + timeout (shim) is still FAIL" 1 "$CODE"

finish_scenario
