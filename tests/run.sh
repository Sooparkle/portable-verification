#!/usr/bin/env bash
# Run all scenarios with an explicit bash binary and report real counts.
#
# Usage: bash tests/run.sh [scenario-name ...]
#        BASH_BIN=/bin/bash bash tests/run.sh      # choose the bash that runs the code under test
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BASH_BIN=${BASH_BIN:-$(command -v bash)}
export BASH_BIN

echo "# bash under test: $BASH_BIN"
"$BASH_BIN" --version | head -n 1 | sed 's/^/# /'
echo "# os: $(uname -srm)"

if [ $# -gt 0 ]; then scenarios=(); for n in "$@"; do scenarios+=("$HERE/scenarios/$n.sh"); done
else scenarios=("$HERE"/scenarios/*.sh); fi

pass=0; fail=0; bad_scenarios=0
for s in "${scenarios[@]}"; do
  echo "# --- $(basename "$s")"
  out=$("$BASH_BIN" "$s" 2>&1); code=$?
  printf '%s\n' "$out" | grep -v '^ok - ' || true
  p=$(printf '%s\n' "$out" | grep -c '^ok - ')
  f=$(printf '%s\n' "$out" | grep -c '^not ok - ')
  pass=$((pass + p)); fail=$((fail + f))
  echo "# $(basename "$s"): $p ok, $f not ok"
  if [ "$code" -ne 0 ] && [ "$f" -eq 0 ]; then echo "# scenario exited $code without a 'not ok' line"; bad_scenarios=$((bad_scenarios + 1)); fi
done

echo "# TOTAL: $pass ok, $fail not ok, $bad_scenarios scenario(s) crashed"
[ "$fail" -eq 0 ] && [ "$bad_scenarios" -eq 0 ] && [ "$pass" -gt 0 ]
