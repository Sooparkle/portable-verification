# Changelog

## 0.1.0 (unreleased)

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

### Known gaps
- Not run: Windows, real `timeout`/`gtimeout` binaries on macOS (a stand-in that exits 124 is used),
  `agentskills validate`, GitHub Actions (the CI files have not run yet), the planted
  `references/ci-github-actions.yml` workflow, loading the skill inside Claude Code / Codex / Cursor / Copilot.
