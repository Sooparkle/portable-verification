# portable-verification

[한국어](README.ko.md)

An agent skill plus a small shell runner. You declare the checks a change must pass in `.verification/checks.txt`; `verify.sh` runs them, stores redacted logs, and prints one status. The agent reports that status; it does not decide it.

**What it guarantees:** declared checks are executed the same way every time, their output is stored, and the status comes from a script instead of the agent's own summary.

**What it does not guarantee:** it is not tamper-proof. An agent (or person) that can edit `checks.txt`, `verify.sh` or environment variables can change the outcome. The script only raises `NEEDS_REVIEW` when it notices such edits. Real enforcement comes from CI with a required status check and a human who reads the flagged diff.

## Install

Needs `bash`, `git`, `perl`. The installer also needs `curl`, `tar`, `gzip`, and `shasum` or `sha256sum`.

### A. Clone, then plant

```bash
git clone https://github.com/OWNER/portable-verification.git
cd portable-verification && git checkout v0.1.0
bash skills/portable-verification/scripts/plant.sh --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
```

`git checkout v0.1.0` leaves you on a detached HEAD. That is expected.

### B. One-line installer (checks a pinned sha256)

Download, read, then run (recommended):

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/OWNER/portable-verification/v0.1.0/install.sh
less install.sh
bash install.sh --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
```

Or pipe it, which runs code you have not read:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/portable-verification/v0.1.0/install.sh | bash -s -- --target ~/work/my-app --agent claude
```

The installer downloads the release archive of its own version and compares its sha256 with the value written inside `install.sh`. If the download fails or the hash differs, it stops before touching your project. This protects against a corrupted or swapped release asset. It does not protect you if the repository itself is compromised and `install.sh` and the hash are replaced together; reading `install.sh` first is the mitigation.

## Planting it in a project

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
| 2 | NEEDS_REVIEW | Checks passed, but test files, test config or `.verification/checks.txt` / `verify.sh` changed, or the change set could not be determined |
| 3 | BLOCKED | Missing or invalid checks file, no required check, or a missing prerequisite |
| 4 | NOT RUN | No check declared, or the run was interrupted |

## Limits

- `TESTS_REVIEWED=1` is a signal set by a person. Locally anyone can set it. In CI it comes from a label, and anyone who can add that label can clear the gate.
- Weakening a check in a way the file patterns do not cover (for example changing the `test` script inside `package.json`) is not detected. Add the file to `FLAG_PATH_REGEX` if that matters to you; expect more false alarms.
- Teams that change tests often will see `NEEDS_REVIEW` often, and may start ignoring it.
- Secret redaction covers environment variable values (names containing TOKEN, SECRET, KEY, PASSWORD, PASSWD, CREDENTIAL, COOKIE; 6+ characters), Authorization/Cookie headers and Bearer tokens. It cannot see secrets hardcoded in files, secrets not in the environment, or screenshots.
- `CHECK_TIMEOUT` needs `timeout` or `gtimeout`. macOS has neither by default (install coreutils); without one the run is `BLOCKED`.
- Tier B (drive the real app) and Tier C (independent review) in `SKILL.md` are instructions. The script only enforces what is declared in `checks.txt`.
- No measurement shows this combination works better than any single one of its sources.
- Windows is untested (use WSL or Git Bash at your own risk).

## What was verified here

Run `BASH_BIN=/bin/bash bash tests/run.sh` yourself; it prints the bash version and the counts.

| Item | Status |
|---|---|
| Scenario tests (verify.sh, plant.sh, install.sh, build) on macOS with the system bash 3.2.57 | run, see CHANGELOG for the date's result |
| Same tests on Linux / newer bash | not run locally; run by CI once the repository is on GitHub |
| Real `timeout` binary | not run (stand-in that exits 124 is used) |
| shellcheck | not run locally (not installed); CI job |
| `agentskills validate` | not run |
| GitHub Actions workflows (this repo's CI and the planted one) | not run yet |
| Loading the skill inside each agent tool | not tested |

## Sources and license

See `skills/portable-verification/SOURCES.md` for the ideas this adapts and how each was checked. That file also states which of its own claims were not audited here. MIT licensed, see `LICENSE`; before redistributing, check the licenses of the sources listed there.
