# Changelog

## 0.2.0 (unreleased)

### Added: portable-eval (experimental)
A second skill, `skills/portable-eval/`: an initial implementation of the small-team subset (section 8) of the
Portable-Eval v2.1 design. The design text is saved unchanged in `docs/design-v2.1.md` with an implementation-status
table on top; what the tool promises is fixed in `docs/contracts.md`.
- `scripts/pe.py` (Python 3.9+, standard library only): `validate`, `gate regression|safety|all`, `compare`, `plan`.
- Four JSON schemas and a JSON Schema subset validator that **blocks on any unsupported keyword**.
- Two modes: `local` (prints `MODE: local (unofficial)`) and `trusted` (`--trusted-ref`: graded with a copy extracted
  from the ref, refuses if the running `pe.py` differs from the ref's, compares the working tree's assets with the
  ref's; seven invariants must hold for a trusted PASS).
- Adapter and grader contracts: no shell, process group kill, time limits, environment allow-list, output size cap,
  grader path confined to `graders/`, self-test against hash-pinned known-bad (and optional known-good) evidence.
- `trials.jsonl` (append-only) is written for every attempt so a later tool can implement design 3.1.
- `plant.sh` for the skill, `references/` templates (placeholders make the gate BLOCKED until filled in), a trusted CI
  workflow template and a CODEOWNERS example.

### Changed
- `verify.sh`: changes under `.eval/` (spec, cases, graders, schemas, refs, snapshots, `pe.py`) now give NEEDS_REVIEW.
  `.eval/runs/` and `system-manifest.json` are not flagged.
- `plant.sh` (both skills): `--check` validates arguments and prerequisites and writes nothing; the target must be writable.
- `install.sh`: `--skill verification|eval|both`, one pinned sha256 per skill, `--archive-dir`, pre-flight
  `plant.sh --check` for every selected skill before the first write. The single `ARCHIVE_SHA256` pin of 0.1.0 is gone.
- `build/build-release.sh` builds one archive per skill; new `build/check-release.sh` verifies the release chain
  (tag commit, CI on that exact commit, pinned hashes, asset hashes, optional rebuild).
- CI: Ubuntu and macOS with Python 3.9 and 3.13, `jsonschema` installed for the schema cross-check.

### Differences from design v2.1 (decisions the design left open)
- JSON instead of YAML; `known_good_ref`, `known_bad_sha256`, `known_good_sha256`, spec `graders` / `adapter` /
  `required_observers`, `decision.safety_trials` (default 3) and evidence `policy_coverage` were added.
- A regression-gate case that stays unrunnable after re-runs is BLOCKED (the design states it only for the safety gate).
- Safety gate target set: `type == safety` cases plus any case with a critical criterion; only critical criteria are
  evaluated; trials are shared with the regression gate; one failed critical criterion in any trial is a FAIL.
- The safety upper bound is computed from the number of risk families, never from the number of cases.
- Regression gate stops early once 2 of the first 3 trials failed (the extra 3 could not change the outcome).
- `compare` also refuses when `decision.fixed_at` is later than a run, or the decision block differs.
- Grader-level self-test coverage: every grader used must fail at least one known-bad evidence (the design asks only
  for a per-case self-test). Without it an always-pass grader could hide behind a second criterion of the same case.
- Not implemented: 3.1 state transitions, 3.3 blind-set operation, 3.4 rubrics, 6.3 judges, 7.2 non-inferiority /
  superiority / equivalence / cost tests, 7.4 portability checks.

### Verified (macOS, Darwin 25.5.0 arm64, bash 3.2.57; details in reports/test-report-v0.2.0.md)
- Full suite five times, 0 failures: Python 3.9.6 + jsonschema 4.25.1 **345 ok** (three runs), Python 3.13.1 +
  jsonschema 4.26.0 **345 ok**, Python 3.9.6 without jsonschema **344 ok** (the cross-check is skipped there).
  Per scenario: consistency 16, eval 86, install 89, plant-eval 39, plant 59, verify 56.
- The schema validator agrees with `jsonschema` on every generated mutant of the four schemas.
- Mutation checks re-run on the final code: 19 of 19 deliberate defects caught (15 in pe.py, 1 in verify.sh, 3 in
  install.sh). The first version of the install tests did **not** catch a skipped pre-flight check; a test was added.
- Seeded simulation through the real scheduling and decision functions matches the design's gate probabilities
  (2,000,000 samples per false-block condition, |z| <= 1.01).
- End-to-end walk-through (`reports/e2e-walkthrough.sh`): 8 of 8 expected outcomes.
- shellcheck 0.11.0 (`--severity=warning`): no findings. `build/check-release.sh v0.1.0 --rebuild`: OK.
- Defects found by this testing and fixed: relative adapter paths did not work; a `severity: critical` label alone
  silently kept a case out of the safety gate (now a warning); an always-pass grader could hide behind a second
  criterion (now grader-level self-test coverage); the install tests could not see a skipped pre-flight check.

### Not run / known gaps
- The workflows of this repository and the planted workflows (`ci-github-actions.yml`, `ci-eval-trusted.yml`) have not run on GitHub.
- Real LLM agent adapters, LLM judges, blind sets, accumulated case state, YAML input, Windows, `agentskills validate`,
  loading the skills inside each agent tool.
- CODEOWNERS, required reviews and required checks are repository settings; nothing here enforces or tests them.
- Official (trusted) results are only as good as the CI that runs a `pe.py` from the base branch; a pull request can edit the workflow file.
- The golden tests prove the formulas equal the design document, not that the design's initial values are right.

## 0.1.0 (2026-11-01)

### Baseline
The skill folder started as the author's draft, imported unchanged in the first commit
("import original draft"). Everything below is a change from that draft; `git log -p` shows each one.

### Changes from the original draft
- **verify.sh: running from a subdirectory.** The draft resolved the default `.verification/checks.txt`
  against the current directory, so running from `repo/sub/` ended in BLOCKED. A relative checks path now
  falls back to the repository root. Found by the test "checks run from the repository root".
- **plant.sh: install record.** Writes `.verification/.plant-manifest` (version, source commit, sha256 of the
  files now on disk). Informational only; it is not an integrity guarantee.
- **plant.sh: VERSION file** is part of the skill folder and is copied; `--force` now reports "replaced"
  instead of "created" when it replaces a folder.
- **SOURCES.md:** the Anthropic code-review article no longer says "user-provided copy" without context;
  it states that no primary URL was found. Added a note that the "no verbatim copy" claim and the
  "How it was checked" column come from the draft and were not audited here.

### Added
- `install.sh`: downloads the release archive, checks its sha256 against a value pinned in the script,
  and only then runs plant.sh. Failure before the check leaves the target project untouched.
- `build/build-release.sh`: builds the archive of `skills/portable-verification/` only (not install.sh),
  with fixed file order, owner, mode, mtime and gzip header.
- `tests/`: scenario tests run with an explicit bash binary (`BASH_BIN`). The draft's own test suite was
  not available, so these tests are new and do not reproduce the draft's "49 scenarios".
- CI for this repository (ubuntu and macOS, shellcheck).

### Verified before the first commit of these changes
- `BASH_BIN=/bin/bash bash tests/run.sh` on macOS (Darwin 25.5.0 arm64), GNU bash 3.2.57: **165 ok, 0 not ok**
  (consistency 9, install 44, plant 56, verify 56).
- Mutation check: deliberately breaking the FAIL verdict, the review gate, log redaction, and the installer's
  checksum comparison each made the matching tests fail (5, 11, 5 and 5 failures); files were restored afterwards.
- Archive build is byte-identical across two builds made one second apart from different working directories
  (same machine, same tar/gzip).

### Verified after release (tag v0.1.0, commit 3653674)
- GitHub Actions: ubuntu bash 5.2.21 166 ok; macOS bash 3.2.57 165 ok; shellcheck 0.9.0 clean.
- install.sh from the public tag URL: sha256 ok, plant ran, verify.sh went NEEDS_REVIEW then PASS after commit.

### Known gaps
- Not run: Windows, real `timeout`/`gtimeout` binaries on macOS (a stand-in that exits 124 is used; Ubuntu CI uses the real one),
  `agentskills validate`, the planted
  `references/ci-github-actions.yml` workflow, loading the skill inside Claude Code / Codex / Cursor / Copilot.
