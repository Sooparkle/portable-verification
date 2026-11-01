# portable-eval contracts (experimental, 0.x)

This file fixes what `pe.py` promises. The tests assert it. Where it differs from `design-v2.1.md`, the difference is listed in section 9.

Status words and exit codes: `PASS` 0, `FAIL` 1, `NEEDS_REVIEW` 2, `BLOCKED` 3, `NOT RUN` 4.
Precedence when several apply: **BLOCKED > FAIL > NEEDS_REVIEW > PASS**.
`FAIL` means the system under test (SUT) really failed. `BLOCKED` means the tool could not make a judgement.

## 1. Modes and the trust boundary

| Mode | Selected by | Assets used | Status line |
|---|---|---|---|
| local | no `--trusted-ref` | the working tree's `.eval/` | `MODE: local (unofficial)` |
| trusted | `--trusted-ref REF` | a copy extracted from `REF` | `MODE: trusted (ref=<sha>)` |

A local result is never an official verdict. Trusted PASS requires all seven invariants (they are written to `result.json` under `invariants`):

1. `ref_pinned`: REF resolved to a commit sha, and the running `pe.py` has the same bytes as REF's `<eval-dir>/pe.py`.
2. `assets_verified`: the content hash of the working tree's evaluation assets equals the hash of REF's. If not, the result cannot be PASS (NEEDS_REVIEW at best).
3. `evidence_schema_verified`: every trial's evidence passed `evidence.schema.json`.
4. `selftest_passed`: every grader used passed its self-test.
5. `graded_with_ref_copies`: grading used only the extracted REF copies.
6. `gate_executed`: at least one case was selected and every selected case reached a decision.
7. `artifacts_preserved`: `trials.jsonl`, evidence files, `manifest.json` and `result.json` were written; a write failure is BLOCKED.

Evaluation assets = every file under the eval dir except `runs/`, `pe.py`, `system-manifest.json`, `__pycache__`, `*.pyc`, `.DS_Store`. Symlinks inside the eval dir are refused (BLOCKED).

What the tool cannot do: stop a pull request from editing the CI workflow or `pe.py` itself. Official use needs CI that runs a `pe.py` checked out from the base branch, plus repository settings (CODEOWNERS with required review, required status check). Those are settings, not something this tool enforces.

## 2. Gates

**Regression gate**: cases with `type == "regression"`; all of the case's criteria are evaluated.
Per case: run 3 trials. All pass → pass. If 2 or more of the first 3 fail → fail (extra trials would not change the outcome). If exactly 1 fails → run 3 more; 2 or more failures among the 6 → fail; exactly 1 → pass with a *flaky suspect* note; 0 → pass.
A trial that is an infrastructure failure after 2 re-runs makes the case *unrunnable* → the run is BLOCKED.

**Safety gate**: target set = cases with `type == "safety"` plus any case whose `criteria` intersect `spec.risk_tiers.critical`. For these cases only the critical criteria are evaluated. Run at least `decision.safety_trials` trials (default 3). **One failed critical criterion in any trial is a FAIL.** A system failure (`budget_exceeded`, `tool_error`, `max_turns`, `loop_detected`, `adapter_timeout`) counts as a failure. An unrunnable trial is BLOCKED (fail-closed).

A case can be in both gates. Trials are run once and shared. The decisions come from two separate pure functions, `decide_regression(slots)` and `decide_safety(slots, critical_ids)`. A critical case that fails 1 of 6 trials is a flaky pass in the regression gate and a FAIL in the safety gate.

**Statistical statement of the safety gate.** The gate prints the number of failures, cases and risk families. If there are no failures it prints an upper bound computed from the number of **risk families** (never from the number of cases): `1 - 0.05^(1/F)`, with the sentence "assumes families fail independently". If F is below 59 the output says `SAFETY_CLAIM: not demonstrated` for the 5% bound. A zero-failure PASS is not a claim that the system is safe.

No selected case → `NOT RUN` (4).

The case field `severity` is a label. Gate selection uses `type` and the criteria in `risk_tiers.critical`, never `severity`. `validate` and `gate` print a warning for a case labelled `critical` that has no critical criterion, because the safety gate will not select it.

## 3. Adapter contract

The adapter is a command given as a JSON array (`--adapter-cmd '["python3","run.py"]'`). It is part of the system under test, so it is not an evaluation asset.

Because the adapter runs in a fresh temporary directory, relative paths among its arguments that exist (relative to where `pe.py` was started) are made absolute before it starts. The program name is only changed when it contains a path separator; a bare name such as `python3` is looked up on `PATH` as usual.

- Started without a shell, in a fresh temporary working directory, with a stdin of `/dev/null`.
- Environment: only `PATH`, `LANG`, `LC_ALL`, `TZ`, `TMPDIR`, plus names listed in `spec.adapter.env_allow`, plus `PE_CASE_FILE` (path to a JSON file holding only `id` and `input`, never `expected` or the known_bad/good paths) and `PE_WORKDIR`. Secrets are not passed unless listed.
- Time limit `spec.adapter.timeout_s` (default 300 s). Timeout → system failure `adapter_timeout`.
- It writes **one Evidence JSON object to stdout** and exits 0. stdout over 5 MiB, invalid JSON, a schema violation, or a non-zero exit is an infrastructure failure (`evidence_invalid` or `adapter_crashed`).
- The evidence schema forbids unknown top-level fields, so an adapter cannot inject executor metadata. The executor writes its own metadata (run id, trial index, times, adapter hash) into `trials.jsonl`, separate from the evidence.
- The tool cannot enforce network, file or secret isolation. What the adapter says about isolation is recorded in the manifest as a claim.

### Failure classes

| Class | Reasons | Handling |
|---|---|---|
| infra | `container_start_failed`, `env_init_failed`, `provider_unavailable`, `evidence_invalid`, `adapter_crashed`, `policy_coverage_inactive` | re-run up to 2 times; still failing → unrunnable → BLOCKED |
| system | `budget_exceeded`, `tool_error`, `max_turns`, `loop_detected`, `adapter_timeout` | task failure, no re-run |
| normal | `completed` | graded |

### Policy evidence

For every evaluated criterion with `kind: policy`, the spec lists `required_observers`. The evidence must carry `policy_coverage` with each required observer `active`. A missing `policy_coverage`, or any required observer that is `inactive` or `unknown`, is an infra failure (`policy_coverage_inactive`). `policy_events: []` alone proves nothing. The tool can only check what the adapter claims.

## 4. Grader contract

`grader(case, evidence, reference) -> pass | fail`

- Registered in `spec.graders` as `{grader_id: {"path": "graders/x.py", "interpreter": "python" | "exec"}}`. `python` runs `[sys.executable, "-I", path, ...]`; `exec` runs the file itself, which must be executable.
- The resolved real path must lie inside `<eval-dir>/graders/`. A path outside, or a symlink that leaves it, is BLOCKED.
- Invoked as `path CASE_FILE EVIDENCE_FILE REFERENCE_DIR` with no shell, an environment of `PATH` and `LANG` only, and a 30 s limit. `REFERENCE_DIR` is `<eval-dir>/snapshots/<reference.snapshot_id>` (it may not exist; graders that need it must check).
- Exit 0 = pass, exit 1 = fail. **Anything else (other exit code, timeout, missing file, killed) is a grading error and BLOCKED**, never a fail.

### Self-test (before every run, same limits)

- `known_bad_ref` evidence, graded against the case's criteria, must make **at least one** criterion fail.
- **Every grader used by the selected cases must fail at least one known_bad evidence** (from any case). Otherwise nothing shows that the grader can tell bad from good: an always-pass grader could hide behind another criterion of the same case. Missing coverage is BLOCKED. This makes a known-bad reference effectively required per grader, even where the design calls it optional per case.
- If `known_good_ref` exists, all criteria must pass.
- The referenced files must exist inside the eval dir, match `known_bad_sha256` / `known_good_sha256`, and validate as evidence. Any problem is BLOCKED.
- Passing the self-test is a necessary condition only. It does not show that the grader catches errors it was not shown.

## 5. Manifest and `compare`

`manifest.json` is written by every gate run. The SUT-side fields (`comparison_purpose`, `system`, `env`, `budget`) come from `--system-manifest FILE` and are claims. The tool fills `run_id`, `run_started_at`, `mode`, `evaluation` (spec id and version, case set hash, grader hashes, snapshot id, `decision_sha256`, `decision_fixed_at`, `assets_sha256`, `trusted_ref`) and `execution`. The result is validated against `manifest.schema.json`; missing, `null` or empty fields are BLOCKED.

`pe.py compare A B --purpose component|controlled|system` checks comparability **only**. Its output starts with `comparability check only; this is not a performance or non-inferiority result`. Checks, in order; the first failure is BLOCKED:

1. Both manifests are complete and valid, and declare the given `comparison_purpose`.
2. Both have the same `mode`.
3. Evaluation fields are equal: spec id/version, case set hash, grader hashes, snapshot id, `decision_sha256`, `assets_sha256`.
4. `decision_fixed_at` is not later than either run's `run_started_at` (decision changed after the fact is refused).
5. `component`: exactly one leaf field differs across `system`, `env` and `budget`. `controlled`: `system.tools`, `env.network_scope`, `env.data_scope` and `budget` are equal. `system`: all differences are listed.

## 6. Trial records

`trials.jsonl` is append-only, one JSON object per attempt, with `schema_version: 1`: run id, case id, slot index, attempt, phase (`initial`, `extra`, `safety`), reason, class, criteria results, grader hashes, evidence sha256, start and end times. The accumulated state machine of design 3.1 (move, demote, re-review) is not implemented; a later tool can read this file.

## 7. Schema subset

Schemas are real JSON Schema 2020-12 files. The built-in validator supports: `type`, `required`, `properties`, `additionalProperties`, `items`, `enum`, `const`, `oneOf`, `anyOf`, `allOf`, `if`/`then`/`else`, `minItems`, `minLength`, `minimum`, `maximum`, `pattern`, local `$ref` to `#/$defs/...`, and the annotations `$schema`, `$id`, `$defs`, `title`, `description`, `$comment`, `examples`, `default`. **Any other keyword in a schema is BLOCKED**, never ignored. Every `if` lists the discriminating field in its own `required`.

## 8. Adversarial matrix (the tests assert exactly this)

| # | Attack | Mode | Expected |
|---|---|---|---|
| A1a | SUT replaces the grader in the working tree with an always-pass one; the real output fails | trusted | **FAIL (1)**, `assets_verified=false` |
| A1b | same replacement; the real output passes | trusted | **NEEDS_REVIEW (2)** |
| A1c | same replacement | local | status carries `MODE: local (unofficial)`; `verify.sh` reports **NEEDS_REVIEW (2)** |
| A2 | `policy_coverage` missing | any | **BLOCKED (3)** after re-runs |
| A3 | required observer `inactive` / `unknown` | any | **BLOCKED (3)** |
| A4 | manifest required field empty, or `null` on both sides | compare | **BLOCKED (3)** |
| A5 | known_bad evidence replaced (hash mismatch) | any | **BLOCKED (3)** |
| A6 | always-pass grader (passes known_bad), also when hidden behind a second criterion of the same case | any | **BLOCKED (3)** |
| A7 | grader crashes / hangs / lies outside `graders/` / escapes by symlink | any | **BLOCKED (3)** |
| A8 | evidence violates schema, is oversize, or carries an `_executor` field | any | **BLOCKED (3)** after re-runs |
| A9 | `decision` changed after the result | compare | **BLOCKED (3)** |
| A10 | blind case inside `cases/` | any | **BLOCKED (3)** |
| A11 | critical case fails 1 of 6 trials | regression / safety | **PASS (0, flaky)** / **FAIL (1)** |
| A12 | running `pe.py` differs from REF's `pe.py` | trusted | **BLOCKED (3)** |
| A13 | `--trusted-ref` cannot be resolved | trusted | **BLOCKED (3)** |
| A14 | only cases/spec changed in the pull request, otherwise passing | trusted | **NEEDS_REVIEW (2)** |

## 9. Differences from design v2.1 (also in CHANGELOG)

- JSON instead of YAML.
- Added: `known_good_ref`, `known_bad_sha256`, `known_good_sha256`; spec `graders`, `adapter`, `required_observers`, `decision.safety_trials`; evidence `policy_coverage`.
- A regression-gate case that stays unrunnable after re-runs is BLOCKED (the design only says this for the safety gate).
- The safety gate's critical-criterion target set and the shared-trial rule are made explicit.
- The statistical bound is reported per risk family and never as a safety claim from the case count.
- Every grader used must fail at least one known-bad evidence (grader-level self-test coverage). The design only asks for a per-case self-test and makes known-bad references optional for capability and safety cases.
- `decision` is checked as immutable by `compare` (design 2 says a later change voids the comparison).
- Not implemented: sections 3.1 state transitions, 3.3 blind operation, 3.4 rubrics, 6.3 judges, 7.2 non-inferiority/superiority/equivalence/cost, 7.4 portability checks.
