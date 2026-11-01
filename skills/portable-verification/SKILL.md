---
name: portable-verification
description: Prove a code change works with executed evidence before calling it done. Use when finishing a feature or bug fix, when asked to verify, test, or reproduce a bug, or before writing a PR body. Runs the project's declared checks through .verification/verify.sh; the script, not the agent, sets the status.
license: MIT
---

# Portable Verification

Paraphrased adaptation of public practices. Sources per section: SOURCES.md.

## Rule zero
- The agent never declares PASS. `.verification/verify.sh` prints the status.
- Report the STATUS line and evidence directory exactly as printed.
- A checklist, a summary, or "it should work" is not evidence.

## Project files (created by scripts/plant.sh)
- `.verification/checks.txt`: one check per line: `id required command`. Fields are separated by spaces or tabs; `required` is yes or no; the command is the rest of the line and runs from the repository root.
- `.verification/feature-map.md`: how each user-facing feature is launched, driven, checked, and cleaned up.
- `.verification/verify.sh`: the runner (copy of this skill's scripts/verify.sh).
- `.verification/evidence/<run>/`: redacted logs, summary.tsv, changed and flagged files, status. Git-ignored.

If checks.txt has no required check for a feature you touched, stop with status BLOCKED and propose the missing lines. Do not run ad-hoc commands and call the result verified.

## Credentials
- Read secrets from environment variables only. Never write a secret into a command, test, fixture, quoted log line, or report.
- verify.sh replaces, in logs, the values of environment variables whose names contain TOKEN, SECRET, KEY, PASSWORD, PASSWD, CREDENTIAL, or COOKIE (6+ characters), plus Authorization/Cookie header values and Bearer tokens, with `<REDACTED>`.
- It cannot see secrets hardcoded in files, secrets not held in environment variables, or secrets in screenshots. Check those by hand before sharing any evidence.

## Pick the tier
| Situation | Run |
|---|---|
| Bug report, failing or slow behavior | Tier A, then Tier B on the affected feature, then Tier C |
| New or changed feature | Tier B, then Tier C |
| Refactor with no intended behavior change | Existing checks, plus Tier B on one main path |
| Docs or copy only | No tier required; write "docs only" in the report |

## Tier A: fast loop (bugs and regressions)
Goal: one command that fails on the user's exact symptom.
- The command must drive the real bug path, give the same verdict every run, finish in seconds, and run without a human.
- Try in this order: focused failing test, HTTP request against a dev server, CLI run with a fixture compared to a snapshot, headless browser script.
- Do not form a hypothesis about the cause before this command exists and has gone red.
- If no such command can be built, stop. List what you tried and which access or artifact is missing. Status: BLOCKED.
- Shrink the repro until removing any remaining element makes it pass.
- Run the loop directly while fixing. When done, add it to checks.txt as a required check.
- Write the regression test only at a seam that reproduces the real call pattern. If no such seam exists, do not write a shallow test. Record it under "Architecture findings" in the report.
- Tag temporary debug logging with a unique prefix (for example `[DEBUG-a4f2]`) and delete all of it before finishing.

## Tier B: real user path (features)
Goal: drive the running app the way a user does and capture evidence.
- Use the Launch, Drive, Side effects, and Cleanup entries from feature-map.md.
- If the harness has its own app runner (for example Claude Code `/verify`, or a pstack-generated `verify-<app>` skill), you may use it for the Drive step. Still record the result through checks.txt or the report.
- Use only inputs a user can reach: no internal setters, no state injection, no mocks a real user would not hit.
- Check side effects (database row, written file, outbound request), not only what the screen shows.
- Stop only processes this session started. Keep evidence files after cleanup.
- Tier B may take minutes. The speed rule from Tier A does not apply here.

## Tier C: independent spec review
Ask a reviewer that did not write the code: "Does this diff implement the originating spec or issue, with nothing missing and nothing extra?"
- Give the reviewer the spec and the diff, not the author's reasoning.
- If the harness cannot start a separate-context reviewer, mark Tier C as NOT INDEPENDENT.
- If no spec or issue exists, mark Tier C as BLOCKED. Do not rebuild a spec from the code.

## Run
    bash .verification/verify.sh

| Exit | Status | Meaning |
|---|---|---|
| 0 | PASS | All required checks passed; no flagged test/config file changed (or a human set TESTS_REVIEWED=1) |
| 1 | FAIL | A required check failed or timed out |
| 2 | NEEDS_REVIEW | Checks passed, but test files, test config, or `.verification/` checks changed, or the change set could not be determined |
| 3 | BLOCKED | Missing or invalid checks file, no required check, or a runner prerequisite missing |
| 4 | NOT RUN | No check declared, or the run was interrupted |

- Never set TESTS_REVIEWED yourself. A human sets it after reading the flagged diff.
- If you changed a test or checks.txt, say why in the report. Weakening a check to get PASS is a FAIL in substance.

## When a check fails
- After 3 failed fix attempts on the same check, stop patching. Write why the approach fails and propose a different approach.
- If the same mistake class appears twice, move its prevention to the strongest layer that can hold it, in this order: code structure or types, lint rule whose message says what to use instead, test, written instruction. Record the choice under "Prevention" in the report.

## Report
Fill references/report-template.md (it doubles as the PR body). Label every result:
- measured: a command ran and its output is in the evidence directory
- inferred: follows from measured facts but was not run
- guess: neither

## Maintenance
- When routes, commands, or features change, update feature-map.md and checks.txt in the same change, then rerun the affected checks.
- Never delete the Credentials section or weaken verify.sh redaction during a rewrite.
