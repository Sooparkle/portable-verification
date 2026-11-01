# Releasing

Rules: never move a published tag, never replace a published release asset. If something is wrong, publish the next patch version.
One tag releases both skills. The two archives contain only `skills/<name>/`, never `install.sh`, so the hashes pinned in `install.sh` do not depend on `install.sh`.

1. Set the version in `skills/portable-verification/VERSION`, `skills/portable-eval/VERSION` and `VERSION=` in `install.sh` (a test checks they agree); update `CHANGELOG.md`.
2. Run the tests: `BASH_BIN=/bin/bash PYTHON_BIN=/usr/bin/python3 bash tests/run.sh`, then again with a newer Python that has `jsonschema` installed. The adversarial matrix in `skills/portable-eval/docs/contracts.md` section 8 must pass completely; one attack that obtains a PASS means no release.
3. Build both archives: `bash build/build-release.sh dist`. It prints one sha256 per archive.
4. In `install.sh` set `SHA256_VERIFICATION=` and `SHA256_EVAL=` to those values (and `REPO=`). The archives do not contain install.sh, so this edit does not change the hashes. Rebuilding the archives must still give the same bytes; if you change anything under `skills/`, go back to step 3.
5. Commit, push, wait for CI to pass on that commit.
6. Tag **that commit** (`git tag -a vX.Y.Z <sha>`), push the tag.
7. Create the GitHub release for the tag and upload the two archives and their `.sha256` files from step 3 (do not rebuild them).
8. Run `bash build/check-release.sh vX.Y.Z --rebuild`. It checks that the tag commit is the commit CI passed on, that the pins in install.sh at the tag are set, that the downloaded assets hash to the pins, and (with `--rebuild`) whether a rebuild is byte-identical. Add `--require-identical` if the same toolchain is used.
9. Install from the public URL into a scratch project (`--skill both`) and run the gates there.

Archive bytes are reproducible for the same input with the same tar/gzip implementation. Different implementations may differ; the pinned hash is the hash of the uploaded asset.
