# Releasing

Rules: never move a published tag, never replace a published release asset. If something is wrong, publish the next patch version.

1. Set the version in `skills/portable-verification/VERSION` and `VERSION=` in `install.sh`; update `CHANGELOG.md`.
2. Run the tests: `BASH_BIN=/bin/bash bash tests/run.sh` (and with a newer bash if available).
3. Build the archive: `bash build/build-release.sh dist`. It prints the sha256.
4. In `install.sh` set `ARCHIVE_SHA256=` to that value and `REPO=` to `owner/name`. The archive does not contain
   install.sh, so this edit does not change the hash.
5. Commit, push, wait for CI to pass on that commit.
6. Tag **that commit** (`git tag -a vX.Y.Z`), push the tag.
7. Create the GitHub release for the tag and upload the same archive file from step 3 (do not rebuild it).
8. Check: `curl -fsSL <release asset URL> | shasum -a 256` equals the pinned value; run `install.sh` from the tag
   into a scratch project.

Archive bytes are reproducible for the same input with the same tar/gzip implementation. Different
implementations may differ; the pinned hash is the hash of the uploaded asset.
