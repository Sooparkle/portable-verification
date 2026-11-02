# Changelog

## 0.2.0 (2026-11-02)

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

### Fixed after the external (Codex) review (reports/codex-review-v0.2.0.md)
- **Trusted PASS could be forged during the run**: an adapter could rewrite the extracted REF grader after the
  self-test. Graders now run from the bytes loaded at the start, the assets used for grading are re-hashed before
  every grading step and at the end (any change: BLOCKED), and trial records/evidence are kept in memory and written
  at the end with their hashes in `result.json`. The adapter gets a private `TMPDIR`. This is detection, not
  isolation; the contracts now say an official verdict also needs the system under test to run as another OS user
  or in a container.
- `compare` checks the decision time of both manifests and requires `decision_fixed_at` to be equal.
- Unexpected errors, a non-object `env`/`system`/`budget` in the system manifest, and I/O errors are BLOCKED
  (no traceback); a failed artifact write is BLOCKED even when the case failed (BLOCKED > FAIL).
- `evidence_schema_verified` is false if any attempt produced invalid evidence, also one that a re-run recovered.
- `plant.sh --check` (both skills) rejects paths of the wrong kind (`.eval` as a file, ...) before anything is written.
- JSON is read strictly (no `NaN`/`Infinity`); `1.0` counts as an integer; `items: false` is supported.
- Self-test coverage is computed over the criteria graded in this run (a safety-only run no longer needs the normal
  graders); the severity warning is printed also when nothing is selected.
- `trials.jsonl` records `adapter_sha256` and per-criterion `grader_sha256`.
- `check-release.sh`: the tag must point to the same commit remotely; every expected CI job must be present (the
  list is kept in step with `ci.yml` by a test); the content of each asset must equal `skills/<skill>/` at the tag.
- Tests: the unittest exit code and test count are now checked by `tests/scenarios/eval.sh`; the oversize-evidence test
  isolates the size cap; attack tests now assert that the attack actually happened.

### Verified (macOS, Darwin 25.5.0 arm64, bash 3.2.57; details and logs in reports/)
- After the review fixes: full suite five times, 0 failures (376 ok; 375 without jsonschema); after three more tests,
  378 ok. Python 3.9.6 and 3.13.1, jsonschema 4.25.1 / 4.26.0 for the cross-check.
- Mutation checks on the final code: 28 of 29 caught. The survivor ("catch-all removed in compare") is not reached by
  the test meant for it; recorded in the report, not fixed.
- Seeded simulation matches the design's gate probabilities (2,000,000 samples per condition, |z| <= 1.01).
- End-to-end walk-through 8/8; shellcheck 0.11.0 no findings; `check-release.sh v0.1.0` OK.
- (These numbers are for e2159ad; the final numbers are under "Fixed after the second review" below.)
- Second external review (Codex, read-only, on e2159ad; `reports/codex-review-r2-v0.2.0.md`): verdict "release after
  fixes". B2, B3, B5, B8, B9 resolved; B1, B4, B6, B7 partly resolved; three regressions found (records of finished
  trials are lost when a run aborts; the manifest hash is taken from a re-read without comparison and `result.json` is
  not read back as the contract says; the executable bit of `exec` graders is no longer required). Fixed below;
  see the report, sections 15 and 16.

### Fixed after the second review (reports/codex-review-r2-v0.2.0.md)
- A run stopped early (BLOCKED during the run, e.g. on tampering) still writes the records and evidence of the trials
  that finished, with their hashes in `result.json`.
- Every artifact (`trials.jsonl`, evidence, `manifest.json`, `result.json`) is written from the bytes held in memory and
  must read back equal to them; the recorded hash is the one of those bytes. `result.json` cannot hold its own hash,
  so it is printed as `RESULT_SHA256: <sha>`.
- An `exec` grader must be executable again (checked when the assets are loaded).
- `1e999` and other numbers that overflow to infinity are refused when JSON is read, also in free-form fields.
- `plant.sh --check` (both skills) also requires search (`x`) permission on existing directories.
- `check-release.sh` checks the tag in the repository named by `install.sh` (`REPO`, where CI and the release are read),
  not `origin`; each asset must hold exactly one top-level folder and only regular files and folders. A new scenario
  (`tests/scenarios/check-release.sh`, fake `gh`, local bare repository) checks that a moved tag, a missing or failed
  CI job, an extra top-level file, changed content, a link and a missing asset are each rejected.
- A test now reaches `compare`'s catch-all (the mutant that survived before).
- The trusted CI template is labelled experimental: as shipped the adapter runs as the same user as `pe.py`, so its
  result is not an official verdict. `docs/contracts.md` section 1 lists the known ways around the run-integrity checks
  (races by an escaped process, start-up code in a writable Python installation, rewriting the run directory) and what
  another OS user or container must not be able to write. `adapter_sha256` is documented as the hash of the command
  line, not of the adapter's code.
- Verified on commit 1c197dc (clean tree; macOS, bash 3.2.57): full suite five times, 0 failures (406 ok; 405 without
  jsonschema; Python 3.9.6 and 3.13.1); mutation checks 41 of 41 caught; e2e 8/8; simulation unchanged;
  `check-release.sh v0.1.0` OK with the v0.1.0 job names. The earlier "compare catch-all" survivor had in fact
  mutated `cmd_validate`'s block; mutants are now split per function and each pattern matches exactly one place.
  shellcheck was not run (not installed here). No third external review.
- CI on 47a2180 (GitHub Actions run 41440627555): Ubuntu (bash 5.2.21) 407 ok and macOS (bash 3.2.57) 406 ok with
  Python 3.9 and 3.13 (Linux also runs the real `timeout` path), shellcheck 0.9.0 clean. First run of this repository's
  tests on Linux.

### Verified after release (tag v0.2.0, commit 56f40b2)
- The first pin commit (d57c2d0) failed CI on Ubuntu: the check-release scenario replaced only `UNSET` pins and so kept
  the released hashes, which a GNU tar rebuild does not reproduce. Fixed in 56f40b2 (tests only; the archives and pins
  did not change). That commit is tagged; CI on it: Ubuntu 409 ok, macOS 408 ok, lint ok (run 41444728772).
- `bash build/check-release.sh v0.2.0 --rebuild --require-identical`: OK (tag in REPO, all five CI jobs, pins, asset
  hashes, asset content equals the tag's `skills/<skill>/`, rebuilt bytes identical).
- `install.sh` downloaded from the public v0.2.0 URL installed both skills into an empty project (both hashes ok);
  `verify.sh` gave NOT RUN (no checks yet) and `pe.py validate` BLOCKED on the placeholders, as designed.

### Not run / known gaps
- The planted workflows (`ci-github-actions.yml`, `ci-eval-trusted.yml`) have not run on GitHub (this repository's own CI has).
- Real LLM agent adapters, LLM judges, blind sets, accumulated case state, YAML input, Windows, `agentskills validate`,
  loading the skills inside each agent tool.
- CODEOWNERS, required reviews and required checks are repository settings; nothing here enforces or tests them.
- Trusted results are only as good as the CI that runs a `pe.py` from the base branch; a pull request can edit the workflow file.
- Same-user runs (the shipped CI template included) detect tampering but do not prevent it; an official verdict needs
  the adapter to run as another OS user or in a container. Not implemented or tested here.
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
