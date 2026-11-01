---
name: portable-eval
description: Run and interpret the project's agent-evaluation gates (regression and safety) with pe.py, and keep evaluation assets trustworthy. Use when changing a prompt, model, tool or harness that is covered by .eval/, when adding or editing evaluation cases or graders, or when asked whether an agent change is safe to ship. Experimental; the script, not the agent, sets the status.
license: MIT
---

# Portable Eval (experimental, 0.x)

This is an initial implementation of the "small team" subset of the Portable-Eval v2.1 design (`docs/design-v2.1.md`). The contracts the tool keeps are in `docs/contracts.md`. It is not a validated evaluation platform: the numbers it prints follow the design document's formulas, and the design's own initial values are unvalidated.

## Rules
- The agent never declares PASS. `python3 -I .eval/pe.py gate ...` prints the status; report the `MODE`, `STATUS` and `EVIDENCE` lines exactly as printed.
- A `MODE: local (unofficial)` result is feedback for development. Never present it as an official verdict. An official verdict is a `MODE: trusted` result from CI (`ci-eval-trusted.yml`).
- Never edit evaluation assets to make a gate pass: `.eval/spec.json`, `cases/`, `graders/`, `refs/`, `snapshots/`, `schemas/`, `pe.py`. If one of them must change, say why in the report; a human reviews it. `verify.sh` reports `NEEDS_REVIEW` for these paths.
- Never put a `blind` case under `.eval/cases/`. The tool refuses it (BLOCKED).
- A passing safety gate is not a safety claim. Read the `SAFETY_CLAIM` line.

## Run
    python3 -I .eval/pe.py validate --eval-dir .eval
    python3 -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd '["python3","-I","adapters/run.py"]'
    python3 -I .eval/pe.py gate safety     --eval-dir .eval --adapter-cmd '[...]'
    python3 -I .eval/pe.py gate all        --eval-dir .eval --adapter-cmd '[...]' --trusted-ref <base-sha>   # CI only

| Exit | Status | Meaning |
|---|---|---|
| 0 | PASS | Every selected case passed (a regression case may pass with one flaky failure in six; it is listed) |
| 1 | FAIL | The system under test failed: regression reproduced, or any critical criterion failed in the safety gate |
| 2 | NEEDS_REVIEW | Results are fine but evaluation assets differ from the trusted ref |
| 3 | BLOCKED | The tool could not judge: invalid assets, grader error, self-test failure, missing policy evidence, unrunnable trials, unresolvable ref |
| 4 | NOT RUN | No case was selected |

Precedence: BLOCKED > FAIL > NEEDS_REVIEW > PASS. Wire the gate into `.verification/checks.txt` as in `references/checks-line.example.md`.

## Adding a case
1. Copy `references/case.template.json` to `.eval/cases/<id>.json`.
2. Save the evidence of the real past failure as `.eval/refs/<id>-bad.json` and pin its hash: `shasum -a 256 .eval/refs/<id>-bad.json` goes into `known_bad_sha256`. A regression case without a known-bad reference is rejected.
3. Run `validate`, then the gate. The grader must fail the known-bad evidence (self-test) or the run is BLOCKED. Every grader in use must be failed by at least one known-bad evidence.
4. To put a case under the safety gate, give it a criterion listed in `risk_tiers.critical` (or `type: safety`). `severity: critical` alone does not select it; `validate` warns about that.

## Report
List: the `MODE`/`STATUS`/`EVIDENCE` lines, flaky suspects, the safety line (cases, families, failures, `SAFETY_CLAIM`), assets that changed and why, and what was not run. Label results measured / inferred / guess as in portable-verification.
