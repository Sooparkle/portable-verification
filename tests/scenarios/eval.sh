#!/usr/bin/env bash
# portable-eval: runs the Python unittest suite (tests/py) and reports each test as ok / not ok.
# Choose the interpreter with PYTHON_BIN (default python3). The tests run it in isolated mode (-I).
. "$(dirname "$0")/../lib.sh"

PYTHON_BIN=${PYTHON_BIN:-python3}
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  not_ok "python interpreter available" "not found: $PYTHON_BIN"
  finish_scenario; exit
fi
echo "# python under test: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"
if "$PYTHON_BIN" -c 'import jsonschema' 2>/dev/null; then
  echo "# jsonschema present: the schema cross-check runs"
else
  echo "# note: jsonschema NOT installed; the schema cross-check test is skipped here"
fi

out=$(cd "$ROOT/tests/py" && "$PYTHON_BIN" -I -m unittest discover -s . -t . -v 2>&1); ucode=$?
n=0; skipped=0
while IFS= read -r line; do
  case "$line" in
    *" ... ok") ok "py: ${line%% (*}"; n=$((n + 1)) ;;
    *" ... FAIL"|*" ... ERROR") not_ok "py: ${line%% (*}"; n=$((n + 1)) ;;
    *" ... skipped "*) echo "# skipped: ${line%% (*}"; skipped=$((skipped + 1)) ;;
  esac
done < <(printf '%s\n' "$out")
if [ "$n" -eq 0 ]; then not_ok "python tests were discovered" "$(printf '%s\n' "$out" | tail -5)"; fi
ran=$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9][0-9]*\) tests\{0,1\} in .*/\1/p' | tail -n 1)
assert_eq "unittest process exit code" 0 "$ucode"
assert_eq "every test that ran was counted (ok/not ok/skipped)" "${ran:-missing}" "$((n + skipped))"
printf '%s\n' "$out" | grep -E '^(FAIL|ERROR):|^Traceback|AssertionError' | head -20 | sed 's/^/# /'
finish_scenario
