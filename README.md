# portable-verification

[한국어](README.ko.md)

Two agent skills with small, dependency-light runners. A script, not the agent, decides the status.

| Skill | Question it answers | Runner | Maturity |
|---|---|---|---|
| `portable-verification` | Does this change work? | `verify.sh` (bash + perl) runs the checks declared in `.verification/checks.txt` | Tested; released since v0.1.0 |
| `portable-eval` | Does this agent system meet its success criteria? | `pe.py` (Python 3.9+, standard library only) runs the regression and safety gates declared in `.eval/` | **Experimental (0.x).** An initial implementation of the small-team subset of the Portable-Eval v2.1 design |

The skills are separate on purpose: different readers (every change vs. prompt/model/tool changes), different trust needs, different maturity. They meet in one place: an eval gate is one line in `checks.txt`.

**What they guarantee:** declared checks run the same way every time, their output is stored, and the status comes from a script, not from the agent's own summary.

**What they do not guarantee:** they are not tamper-proof. An agent (or person) who can edit `checks.txt`, `verify.sh`, the evaluation assets or environment variables can change the outcome. The scripts raise `NEEDS_REVIEW` when they notice such edits. Real enforcement comes from CI with a required status check and a human who reads the flagged diff.

## Install

Needs `bash`, `git`, `perl`; `portable-eval` also needs `python3` 3.9 or newer. The installer also needs `curl`, `tar`, `gzip`, and `shasum` or `sha256sum`.

### A. Clone, then plant

```bash
git clone https://github.com/Sooparkle/portable-verification.git
cd portable-verification && git checkout v0.2.0
bash skills/portable-verification/scripts/plant.sh --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
bash skills/portable-eval/scripts/plant.sh --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
```

`git checkout v0.2.0` leaves you on a detached HEAD. That is expected. Plant only the skill(s) you want.

### B. Installer (checks pinned sha256 values)

Download, read, then run (recommended). `--skill` is `verification` (default), `eval` or `both`:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/Sooparkle/portable-verification/v0.2.0/install.sh
less install.sh
bash install.sh --skill both --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
```

Or pipe it, which runs code you have not read:

```bash
curl -fsSL https://raw.githubusercontent.com/Sooparkle/portable-verification/v0.2.0/install.sh | bash -s -- --skill both --target ~/work/my-app --agent claude
```

The installer downloads the release archive of each selected skill and compares its sha256 with the value written inside `install.sh`. It runs `plant.sh --check` for every selected skill, and only then writes to your project. If a download fails, a hash differs or a pre-flight check fails, it stops with your project untouched (also when `both` is selected: nothing is installed). The pinned hash protects against a corrupted or swapped release asset. It does not protect you if the repository itself is compromised and `install.sh` and the hashes are replaced together; reading `install.sh` first is the mitigation. The install is not transactional: an I/O error while writing (disk full) can leave a partial install; `plant.sh` is idempotent, so run it again.

## Planting portable-verification in a project

1. **Run A or B** from above. Pick the folder your agent reads (table below). With no `--agent`, plant.sh guesses from `.claude/`, `.cursor/`, `.agents/` or `AGENTS.md`, and falls back to `.agents/skills/`.
2. **What appears in the project:**

```text
my-app/
├── .claude/skills/portable-verification/   # the skill (rules the agent reads); folder depends on --agent
├── .verification/
│   ├── checks.txt          # what must pass: YOU edit this
│   ├── feature-map.md      # how each user-facing feature is launched and driven: YOU fill this
│   ├── verify.sh           # the runner (copy)
│   ├── .plant-manifest     # version and hashes of what was installed (informational)
│   └── evidence/           # logs of each run; git-ignored
├── CLAUDE.md               # only with --pointer: a short marked block pointing at the skill
└── .github/workflows/verification.yml   # only with --ci github
```

3. **Enable checks.** plant.sh looks at `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `gradlew`, `pom.xml`, `pubspec.yaml` and `Makefile` and writes suggestions as comments. Nothing runs until you delete the leading `#`. Format: `id required command`, separated by spaces or tabs.

```text
unit       yes  pnpm run test
typecheck  yes  pnpm run typecheck
e2e-login  yes  pnpm exec playwright test tests/e2e/login.spec.ts
lint       no   pnpm run lint
```

4. **Fill `feature-map.md`** for the 3 to 5 features users depend on most: how to launch, drive, check side effects, and clean up.
5. **First run and commit.**

```bash
bash .verification/verify.sh
```

   The first run reports `NEEDS_REVIEW` because the new files are not committed yet. That is the designed behavior: a changed `checks.txt` always needs a human look. Read the files, commit them (skill folder, `.verification/`, `.gitignore`), run again, and a passing project reports `PASS`.
6. **Enforce it (optional, recommended).** Mark the `verify` job as a required status check in branch protection. A pull request that changes test files stops at `NEEDS_REVIEW` until a person reads the diff and adds the `tests-reviewed` label. Without this step the module is only guidance that an agent may or may not follow.

**Update:** `git fetch --tags`, `git checkout vX.Y.Z`, run plant.sh again with `--force`. `--force` replaces the skill folder and `.verification/verify.sh`; `checks.txt`, `feature-map.md` and an existing CI workflow are never overwritten. A skill folder or `verify.sh` that differs from the new version is skipped unless you pass `--force`.

**Remove:** delete the skill folder, `.verification/`, the `.verification/evidence/` line in `.gitignore`, and the block between `portable-verification:start` and `portable-verification:end` in the pointer file.

## portable-eval (experimental)

An initial implementation of the "small team" subset (section 8) of the design in `skills/portable-eval/docs/design-v2.1.md`. What the tool promises is fixed in `skills/portable-eval/docs/contracts.md`; the tests assert it. It is **not** a validated evaluation platform: its numbers follow the design document's formulas, and the design's own initial values are unvalidated.

What is implemented: spec/case/manifest validation, a regression gate (3 trials, 3 more on a failure, blocked at 2 failures in 6), a safety gate (any failed critical criterion is a FAIL), grader self-tests against pinned known-bad evidence, policy-evidence checks, a comparability check for run manifests, a sample-size calculator. What is not: case promotion/demotion over time, blind-set operation, rubrics, LLM judges, non-inferiority/superiority/equivalence tests, portability checks.

Planting it creates `.eval/` with `pe.py`, `schemas/`, and a `spec.json` / `system-manifest.json` full of `REPLACE` placeholders. The gate refuses to run (BLOCKED) until a human fills them in. You write the graders, cases and the adapter (the adapter is part of the system under test, not an evaluation asset).

```text
my-app/
├── .claude/skills/portable-eval/   # the skill, with docs/contracts.md and docs/design-v2.1.md
├── .eval/
│   ├── spec.json               # criteria, graders, risk tiers, decision block: YOU fill this
│   ├── system-manifest.json    # model, harness, prompt hash, tools, budget: YOU fill this (claims)
│   ├── cases/  graders/  refs/ # YOUR cases, graders and pinned known-bad evidence
│   ├── schemas/  pe.py         # the tool and its schemas (copies)
│   └── runs/                   # trial records, evidence, manifests; git-ignored
└── .github/workflows/eval.yml  # only with --ci github: the trusted gate
```

```bash
python3 -I .eval/pe.py validate --eval-dir .eval
python3 -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd '["python3","-I","adapters/run.py"]'
python3 -I .eval/pe.py gate all --eval-dir .eval --adapter-cmd '["python3","-I","adapters/run.py"]' --trusted-ref origin/main
```

**Two modes, and why.** A local run uses the working tree's `.eval/` and prints `MODE: local (unofficial)`: it is feedback, not a verdict, because whoever changes the code under test can also change the graders. A trusted run (`--trusted-ref`) grades with a copy extracted from a protected ref, refuses to run if the running `pe.py` differs from that ref's `pe.py`, and compares the working tree's evaluation assets with the ref's: a difference can only end as `NEEDS_REVIEW`, never `PASS`. A trusted PASS needs seven invariants (listed in `result.json`). Precedence: BLOCKED > FAIL > NEEDS_REVIEW > PASS.

The adapter runs with the same user rights as `pe.py`. The tool runs graders from the bytes it loaded at the start, re-hashes the assets before every grading step, and writes trial records only at the end, so an adapter that rewrites a grader or deletes records during the run ends in BLOCKED. That is detection, not isolation: the adapter can still race the tool, or plant start-up code in a Python installation it can write to. For an official verdict the system under test must run as a different OS user or in a separate container that cannot write to `pe.py`, the trusted checkout, the Python installation, the temporary directory and the run output, which the tool cannot check (see `docs/contracts.md` section 1).

Wire it into verification with one line in `checks.txt` (local feedback), and run the trusted gate in CI:

```text
eval-regression  yes  python3 -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd '["python3","-I","adapters/run.py"]'
```

`verify.sh` reports `NEEDS_REVIEW` when anything under `.eval/` (spec, cases, graders, schemas, refs, snapshots, `pe.py`) changed. The trusted gate belongs in CI; `references/ci-eval-trusted.yml` runs `pe.py` and the assets from the pull request's base commit. As shipped it runs the adapter as the same user, so it is experimental, not an official verdict. That workflow can itself be edited by a pull request, so protect `.github/` and `.eval/` with CODEOWNERS plus required code-owner review (`references/CODEOWNERS.example`) and make the job a required check. Those are repository settings; the tool cannot enforce them.

A passing safety gate is not a safety claim. The gate prints the number of risk families and says `SAFETY_CLAIM: not demonstrated` until there are enough independent families (59 for a 5% bound, assuming independence).

## Which `--agent` value

| Tool | `--agent` | Skill folder | Official docs checked | Skill loading tested in the tool |
|---|---|---|---|---|
| Claude Code | `claude` | `.claude/skills/` | yes, by the draft's author (code.claude.com) | no |
| Codex | `agents` | `.agents/skills/` | yes, by the draft's author (developers.openai.com) | no |
| Cursor | `cursor` | `.cursor/skills/` | no | no |
| GitHub Copilot | `github` | `.github/skills/` (also reads `.claude/skills`, `.agents/skills`) | no, second-hand source only | no |

"Tested" for every row means only that plant.sh puts the files in that folder (covered by tests). Whether each tool then loads the skill has not been checked here. Pass one `--agent`; with several, a tool that reads more than one folder may list the skill twice.

## Statuses

| Exit | Status | Meaning |
|---|---|---|
| 0 | PASS | All required checks passed and no flagged test/config file changed (or a human set `TESTS_REVIEWED=1`) |
| 1 | FAIL | A required check failed or timed out. `TESTS_REVIEWED=1` never changes this |
| 2 | NEEDS_REVIEW | Checks passed, but test files, test config, `.verification/checks.txt` / `verify.sh` or `.eval/` assets changed, or the change set could not be determined |
| 3 | BLOCKED | Missing or invalid checks file, no required check, or a missing prerequisite |
| 4 | NOT RUN | No check declared, or the run was interrupted |

`pe.py` uses the same exit codes: 1 means the system under test failed, 3 means the tool could not judge (invalid assets, grader error, self-test failure, missing policy evidence, unrunnable trials), 4 means no case was selected.

## Limits

- `TESTS_REVIEWED=1` is a signal set by a person. Locally anyone can set it. In CI it comes from a label, and anyone who can add that label can clear the gate.
- Weakening a check in a way the file patterns do not cover (for example changing the `test` script inside `package.json`) is not detected. Add the file to `FLAG_PATH_REGEX` if that matters to you; expect more false alarms.
- Teams that change tests often will see `NEEDS_REVIEW` often, and may start ignoring it.
- Secret redaction covers environment variable values (names containing TOKEN, SECRET, KEY, PASSWORD, PASSWD, CREDENTIAL, COOKIE; 6+ characters), Authorization/Cookie headers and Bearer tokens. It cannot see secrets hardcoded in files, secrets not in the environment, or screenshots.
- `CHECK_TIMEOUT` needs `timeout` or `gtimeout`. macOS has neither by default (install coreutils); without one the run is `BLOCKED`.
- Tier B (drive the real app) and Tier C (independent review) in `SKILL.md` are instructions. The script only enforces what is declared in `checks.txt`.
- portable-eval: environment isolation and policy observers are claims made by the adapter; the tool only checks what is claimed. Local results are unofficial. Trusted results from the shipped CI template are not official either (the adapter runs as the same user); official results also depend on repository settings the tool cannot enforce. Gate probabilities assume independent cases and a constant per-trial reliability; a shared outage breaks that assumption.
- No measurement shows this combination works better than any single one of its sources.
- Windows is untested (use WSL or Git Bash at your own risk).

## What was verified here

Run `BASH_BIN=/bin/bash PYTHON_BIN=python3 bash tests/run.sh` yourself; it prints the bash and Python versions and the counts.

| Item | Status |
|---|---|
| bash scenario tests, python unit tests, adversarial matrix A1-A14 on macOS (bash 3.2.57, system Python 3.9.6) | see CHANGELOG for the counts of the release |
| Same on Ubuntu and on newer bash/Python | run by GitHub Actions once the change is pushed; see the CI log |
| Schema validator cross-check against `jsonschema` | run locally in a throw-away venv and in CI; skipped when the library is absent |
| Mutation checks (breaking a rule on purpose makes a test fail) | run by hand; the results are in the CHANGELOG |
| Real `timeout` binary | Ubuntu CI only; on macOS a stand-in that exits 124 is used |
| `agentskills validate` | not run |
| The workflows planted into projects (`ci-github-actions.yml`, `ci-eval-trusted.yml`) | not run |
| A real LLM agent behind the adapter, LLM judges, blind sets | not implemented, not run |
| Loading the skills inside each agent tool | not tested |
| Windows | not tested |

## Sources and license

See `skills/portable-verification/SOURCES.md` for the ideas portable-verification adapts and how each was checked, and `skills/portable-eval/docs/design-v2.1.md` section 10 for portable-eval. SOURCES.md also states which of its own claims were not audited here. MIT licensed, see `LICENSE`; before redistributing, check the licenses of the sources listed there.
