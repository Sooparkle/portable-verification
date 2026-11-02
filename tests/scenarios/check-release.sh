#!/usr/bin/env bash
# build/check-release.sh must reject a broken release chain, not only pass a good one.
# GitHub is replaced by a local bare repository (CHECK_RELEASE_REMOTE) and a fake `gh` on PATH that serves
# check runs and release assets from files.
. "$(dirname "$0")/../lib.sh"

CHECK="$ROOT/build/check-release.sh"
src="$WORK/rel"; mkdir -p "$src"
git -C "$ROOT" archive HEAD install.sh skills build | tar -x -C "$src"
# the release tools under test are the working-tree ones
cp "$ROOT/build/build-release.sh" "$src/build/build-release.sh"
version=$(tr -d '[:space:]' < "$src/skills/portable-eval/VERSION")
tag="v$version"

dist="$WORK/dist"
"$BASH_BIN" "$src/build/build-release.sh" "$dist" >/dev/null 2>&1 || not_ok "build the test archives"
pv=$(sum256 "$dist/portable-verification-skill-$tag.tar.gz"); pe=$(sum256 "$dist/portable-eval-skill-$tag.tar.gz")
sed -e "s/^SHA256_VERIFICATION=\"[^\"]*\"/SHA256_VERIFICATION=\"$pv\"/" -e "s/^SHA256_EVAL=\"[^\"]*\"/SHA256_EVAL=\"$pe\"/" \
  "$src/install.sh" > "$src/install.sh.new" && mv "$src/install.sh.new" "$src/install.sh"
# the pins must be the hashes of the archives built here (whether install.sh had UNSET or a real release pin):
# another tar/gzip gives other bytes than the released archives
assert_eq "test install.sh pins the test-built verification archive" "$pv" "$(sed -n 's/^SHA256_VERIFICATION="\([^"]*\)".*/\1/p' "$src/install.sh")"
assert_eq "test install.sh pins the test-built eval archive" "$pe" "$(sed -n 's/^SHA256_EVAL="\([^"]*\)".*/\1/p' "$src/install.sh")"
(cd "$src" && git init -q -b main && git add -A && git commit -q -m release && git tag "$tag")
remote="$WORK/remote.git"; git clone -q --bare "$src" "$remote"

# fake gh: `gh api .../check-runs` prints $STUB_CHECKS; `gh release download TAG --repo R -p NAME -D DIR` copies from $STUB_ASSETS
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  api) cat "$STUB_CHECKS" ;;
  release)
    shift 2; name=""; dir=""
    while [ $# -gt 0 ]; do case "$1" in -p) name=$2; shift 2 ;; -D) dir=$2; shift 2 ;; *) shift ;; esac; done
    [ -f "$STUB_ASSETS/$name" ] || exit 1
    cp "$STUB_ASSETS/$name" "$dir/$name" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/gh"

all_checks="$WORK/checks-all"
sed -n 's/^EXPECTED_CHECKS="\(.*\)"$/\1/p' "$CHECK" | tr ';' '\n' | sed 's/$/	success/' > "$all_checks"

run_check() { # CHECKS_FILE ASSETS_DIR [REMOTE] -> OUT, CODE
  OUT=$(cd "$src" && PATH="$WORK/bin:$PATH" STUB_CHECKS="$1" STUB_ASSETS="$2" CHECK_RELEASE_REMOTE="${3:-$remote}" \
        "$BASH_BIN" "$CHECK" "$tag" 2>&1 </dev/null); CODE=$?
}

run_check "$all_checks" "$dist"
assert_eq "a correct release chain passes" 0 "$CODE"
assert_contains "the tag is checked in REPO, not origin" "$OUT" "tag in Sooparkle/portable-verification points to the same commit"

# 1. the tag in REPO points elsewhere
moved="$WORK/moved.git"; git clone -q --bare "$src" "$moved"
other=$(cd "$src" && git commit -q --allow-empty -m other && git rev-parse HEAD)
(cd "$src" && git push -q "$moved" HEAD:refs/heads/other && git reset -q --hard "$tag")
git -C "$moved" tag -f "$tag" "$other" >/dev/null
run_check "$all_checks" "$dist" "$moved"
assert_eq "a tag that points elsewhere in REPO fails" 1 "$CODE"
assert_contains "the moved tag is named" "$OUT" "points to $other"
run_check "$all_checks" "$dist" "$WORK/no-such-remote.git"
assert_eq "a tag missing in REPO fails" 1 "$CODE"

# 2. CI: a missing job, a failed job
grep -v '^lint' "$all_checks" > "$WORK/checks-nolint"
run_check "$WORK/checks-nolint" "$dist"
assert_eq "a missing expected CI job fails" 1 "$CODE"
assert_contains "the missing job is named" "$OUT" "expected CI jobs missing: [lint]"
sed '1s/success$/failure/' "$all_checks" > "$WORK/checks-failed"
run_check "$WORK/checks-failed" "$dist"
assert_eq "a failed CI job fails" 1 "$CODE"

# 4/5. assets: extra top-level file, changed content, link, missing asset
tamper() { # NAME: copy dist to $WORK/assets-NAME, unpack the eval archive into $WORK/x-NAME for editing
  rm -rf "$WORK/assets-$1" "$WORK/x-$1"; cp -R "$dist" "$WORK/assets-$1"; mkdir -p "$WORK/x-$1"
  tar -xzf "$dist/portable-eval-skill-$tag.tar.gz" -C "$WORK/x-$1"
}
repack() { # NAME
  (cd "$WORK/x-$1" && COPYFILE_DISABLE=1 tar -cf - . | gzip -n > "$WORK/assets-$1/portable-eval-skill-$tag.tar.gz")
}
tamper extra; echo hi > "$WORK/x-extra/EXTRA.txt"; repack extra
run_check "$all_checks" "$WORK/assets-extra"
assert_eq "an asset with an extra top-level file fails" 1 "$CODE"
assert_contains "the extra top-level entry is named" "$OUT" "top level must be only portable-eval/"

tamper changed; echo "# changed" >> "$WORK/x-changed/portable-eval/SKILL.md"; repack changed
run_check "$all_checks" "$WORK/assets-changed"
assert_eq "an asset whose content differs from the tag fails" 1 "$CODE"
assert_contains "the content difference is reported" "$OUT" "content differs from skills/portable-eval"

tamper link; ln -s /etc/passwd "$WORK/x-link/portable-eval/passwd"; repack link
run_check "$all_checks" "$WORK/assets-link"
assert_eq "an asset holding a link fails" 1 "$CODE"
assert_contains "the link is reported" "$OUT" "holds links or special files"

tamper missing; rm "$WORK/assets-missing/portable-eval-skill-$tag.tar.gz"
run_check "$all_checks" "$WORK/assets-missing"
assert_eq "a missing asset fails" 1 "$CODE"

finish_scenario
