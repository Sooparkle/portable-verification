#!/usr/bin/env bash
# portable-verification runner. Runs the declared checks, stores redacted logs,
# and prints one status. The status comes from this script, not from an agent.
#
# Usage:  bash .verification/verify.sh [checks-file]   (default .verification/checks.txt)
# Exit:   0 PASS | 1 FAIL | 2 NEEDS_REVIEW | 3 BLOCKED | 4 NOT RUN
#
# Optional environment:
#   BASE_REF         git ref to diff against (default: first of origin/HEAD, origin/main,
#                    origin/master, main, master that exists)
#   FLAG_PATH_REGEX  extended regex for test/config paths whose change forces NEEDS_REVIEW
#   CHECK_TIMEOUT    seconds per check (needs `timeout` or `gtimeout`)
#   EVIDENCE_ROOT    default .verification/evidence
#   TESTS_REVIEWED=1 set only by a human after reading the flagged diff
#
# Written for bash 3.2+ (macOS default): no mapfile, no associative arrays.
set -uo pipefail

CHECKS_ARG="${1:-.verification/checks.txt}"
case "$CHECKS_ARG" in /*) CHECKS_FILE="$CHECKS_ARG" ;; *) CHECKS_FILE="$PWD/$CHECKS_ARG" ;; esac

DEFAULT_FLAG_REGEX='(^|/)(tests?|__tests__|specs?|e2e|__snapshots__|fixtures)/'
DEFAULT_FLAG_REGEX="$DEFAULT_FLAG_REGEX"'|[._-](test|spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$|\.snap$'
DEFAULT_FLAG_REGEX="$DEFAULT_FLAG_REGEX"'|(^|/)(jest|vitest|playwright|cypress|karma)\.config\.[A-Za-z0-9]+$'
DEFAULT_FLAG_REGEX="$DEFAULT_FLAG_REGEX"'|(^|/)(pytest\.ini|conftest\.py|tox\.ini|phpunit\.xml)$'
DEFAULT_FLAG_REGEX="$DEFAULT_FLAG_REGEX"'|(^|/)\.verification/(checks\.txt|verify\.sh)$'
FLAG_PATH_REGEX="${FLAG_PATH_REGEX:-$DEFAULT_FLAG_REGEX}"

ROOT="${VERIFY_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
if ! cd "$ROOT"; then echo "STATUS: BLOCKED (cannot enter $ROOT)"; exit 3; fi

EVIDENCE_ROOT="${EVIDENCE_ROOT:-.verification/evidence}"
run_dir="$EVIDENCE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
if ! mkdir -p "$run_dir"; then echo "STATUS: BLOCKED (cannot create $run_dir)"; exit 3; fi

finish() { # status detail exit-code
  printf '%s\n' "$1" > "$run_dir/status"
  printf '%s\n' "${2:-}" > "$run_dir/status-detail"
  printf '%s\n' "$run_dir" > "$EVIDENCE_ROOT/LATEST"
  echo "STATUS: $1${2:+ ($2)}"
  echo "EVIDENCE: $run_dir"
  exit "$3"
}
trap 'finish "NOT RUN" "interrupted" 4' INT TERM

# Redact secrets in place. Values of secret-looking env vars (6+ chars, longest first),
# Authorization/Cookie header values, and Bearer tokens become <REDACTED>.
scrub() {
  perl -i -pe '
    BEGIN {
      @s = sort { length($b) <=> length($a) }
           grep { defined($_) && length($_) >= 6 }
           map  { $ENV{$_} }
           grep { /TOKEN|SECRET|KEY|PASSWORD|PASSWD|CREDENTIAL|COOKIE/i } keys %ENV;
    }
    for my $v (@s) { s/\Q$v\E/<REDACTED>/g }
    s/((?:Proxy-)?Authorization:\s*)\S.*/$1<REDACTED>/gi;
    s/((?:Set-)?Cookie:\s*)\S.*/$1<REDACTED>/gi;
    s/(Bearer\s+)[A-Za-z0-9._~+\/=-]{8,}/$1<REDACTED>/g;
  ' "$1"
}

command -v perl >/dev/null 2>&1 || finish BLOCKED "perl not found; log redaction cannot run" 3
[ -f "$CHECKS_FILE" ] || finish BLOCKED "no checks file: $CHECKS_ARG" 3

timeout_bin=""
if [ -n "${CHECK_TIMEOUT:-}" ]; then
  if command -v timeout >/dev/null 2>&1; then timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then timeout_bin=gtimeout
  else finish BLOCKED "CHECK_TIMEOUT is set but neither timeout nor gtimeout exists" 3; fi
fi

# Pass 1: parse and validate. Format per line: id required command...
# Fields are separated by spaces or tabs; the command is the rest of the line.
count=0; n_required=0; seen=" "; errors="$run_dir/checks-errors.txt"; : > "$errors"
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%$'\r'}
  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in ''|'#'*) continue ;; esac
  id=${line%%[[:space:]]*}
  rest=${line#"$id"}; rest="${rest#"${rest%%[![:space:]]*}"}"
  required=${rest%%[[:space:]]*}
  cmd=${rest#"$required"}; cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  case "$id" in
    [A-Za-z0-9]*) case "$id" in *[!A-Za-z0-9._-]*) echo "line $lineno: id '$id' may use only letters, digits, . _ -" >> "$errors"; continue ;; esac ;;
    *) echo "line $lineno: id '$id' must start with a letter or digit" >> "$errors"; continue ;;
  esac
  case "$required" in yes|no) ;; *) echo "line $lineno: second field must be yes or no, got '$required'" >> "$errors"; continue ;; esac
  [ -n "$cmd" ] || { echo "line $lineno: missing command" >> "$errors"; continue; }
  case "$seen" in *" $id "*) echo "line $lineno: duplicate id '$id'" >> "$errors"; continue ;; esac
  seen="$seen$id "
  c_id[$count]=$id; c_req[$count]=$required; c_cmd[$count]=$cmd
  count=$((count + 1))
  [ "$required" = yes ] && n_required=$((n_required + 1))
done < "$CHECKS_FILE"

if [ -s "$errors" ]; then
  cat "$errors"
  finish BLOCKED "invalid checks file: $(head -n 1 "$errors")" 3
fi
[ "$count" -gt 0 ] || finish "NOT RUN" "no checks declared in $CHECKS_ARG" 4
[ "$n_required" -gt 0 ] || finish BLOCKED "no check has required=yes in $CHECKS_ARG" 3

# Pass 2: run every check from the repository root.
summary="$run_dir/summary.tsv"
printf 'id\trequired\texit\tseconds\tresult\tlog\n' > "$summary"
failed_required=0; failed_optional=0
i=0
while [ "$i" -lt "$count" ]; do
  id=${c_id[$i]}; required=${c_req[$i]}; cmd=${c_cmd[$i]}
  log="$run_dir/$id.log"
  printf '# check: %s (required: %s)\n# command: %s\n# started: %s\n\n' \
    "$id" "$required" "$cmd" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$log"
  start=$(date +%s)
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" "$CHECK_TIMEOUT" bash -c "$cmd" >> "$log" 2>&1 < /dev/null
  else
    bash -c "$cmd" >> "$log" 2>&1 < /dev/null
  fi
  code=$?
  secs=$(( $(date +%s) - start ))
  printf '\n# exit: %s  seconds: %s\n' "$code" "$secs" >> "$log"
  if ! scrub "$log"; then rm -f "$log"; finish BLOCKED "redaction failed for check $id; log deleted" 3; fi
  if [ "$code" -eq 0 ]; then result=pass
  elif [ -n "$timeout_bin" ] && [ "$code" -eq 124 ]; then result=timeout
  else result=fail; fi
  if [ "$result" != pass ]; then
    if [ "$required" = yes ]; then failed_required=$((failed_required + 1)); else failed_optional=$((failed_optional + 1)); fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$required" "$code" "$secs" "$result" "$log" >> "$summary"
  printf '[%-7s] %s (required: %s, exit %s, %ss)\n' "$result" "$id" "$required" "$code" "$secs"
  i=$((i + 1))
done

# Change set: committed since the merge base, uncommitted, and untracked files.
change_state=UNKNOWN; base=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "${BASE_REF:-}" ]; then
    git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null && base=$BASE_REF
  else
    for r in origin/HEAD origin/main origin/master main master; do
      if git rev-parse --verify --quiet "${r}^{commit}" >/dev/null; then base=$r; break; fi
    done
  fi
  changed="$run_dir/changed-files.txt"
  if [ -n "$base" ] && { git diff --name-only "$base...HEAD" && git diff --name-only HEAD \
       && git ls-files --others --exclude-standard; } > "$changed" 2>/dev/null; then
    sort -u -o "$changed" "$changed"
    grep -E "$FLAG_PATH_REGEX" "$changed" > "$run_dir/flagged-files.txt"
    case $? in 0) change_state=CHANGED ;; 1) change_state=NONE ;; *) change_state=UNKNOWN ;; esac
  fi
fi
printf 'base=%s\nchange_state=%s\n' "${base:-none}" "$change_state" > "$run_dir/change-set.txt"

opt=""; [ "$failed_optional" -gt 0 ] && opt="; optional failures: $failed_optional"
[ "$failed_required" -gt 0 ] && finish FAIL "required failures: $failed_required$opt; see $summary" 1
if [ "$change_state" != NONE ]; then
  if [ "${TESTS_REVIEWED:-}" = 1 ]; then
    finish PASS "test/config changes ($change_state) marked reviewed by a human via TESTS_REVIEWED=1$opt" 0
  fi
  [ "$change_state" = CHANGED ] && sed -n '1,20s/^/  flagged: /p' "$run_dir/flagged-files.txt"
  finish NEEDS_REVIEW "test/config files $change_state against ${base:-unknown base}$opt" 2
fi
finish PASS "all $n_required required checks passed$opt" 0
