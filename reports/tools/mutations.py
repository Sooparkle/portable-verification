"""Mutation checks: each deliberate defect must make at least one test fail.
Usage: python3 reports/tools/mutations.py   (PYTHON_BIN selects the interpreter for the unit tests)
Re-run every mutation check against the current code. Each mutation is applied, the relevant tests run,
the file is restored from memory and its hash re-checked. Prints one line per mutation."""
import hashlib
import os
import re
import subprocess
import sys

REPO = os.environ.get("REPO") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PE = "skills/portable-eval/scripts/pe.py"
VS = "skills/portable-verification/scripts/verify.sh"
INS = "install.sh"
PY = os.environ.get("PYTHON_BIN", sys.executable)

M = [
    ("pe", "safety gate never fails on a violation", PE, '    return "fail" if failed else "pass"', '    return "pass"', ["TestGateLocal", "TestContracts"]),
    ("pe", "grader self-test skipped", PE, '        selftest(assets, [selected[k] for k in sorted(selected)], run.grader_hashes, graded)', '        pass', ["test_a6", "test_selftest", "every_used"]),
    ("pe", "known_bad hash pin not checked", PE, '    if sha256_bytes(data) != case[key + "_sha256"]:', '    if False:', ["test_a5"]),
    ("pe", "trusted asset comparison ignored", PE, '            if head_digest != ref_digest:', '            if False:', ["TestTrusted"]),
    ("pe", "regression blocks on a single failure", PE, '    if fails >= 2:\n        return "fail"\n    if fails == 1:\n        return "flaky"', '    if fails >= 1:\n        return "fail"', ["test_flaky", "test_critical", "test_all_gate"]),
    ("pe", "running pe.py not compared with the ref", PE, '                if f.read() != ref_pe:', '                if False:', ["test_a12"]),
    ("pe", "policy coverage not checked", PE, '    cov = evidence.get("policy_coverage")', '    return True\n    cov = evidence.get("policy_coverage")', ["test_a2", "test_a3"]),
    ("pe", "oneOf accepts several matches", PE, '        if n_ok != 1:', '        if n_ok < 1:', ["SchemaValidator"]),
    ("pe", "decision-after-the-fact check removed", PE, '                if parse_when(m["evaluation"]["decision_fixed_at"]) > parse_when(other["run_started_at"]):', '                if False:', ["TestCompare"]),
    ("pe", "decision_fixed_at not compared between manifests", PE, '"decision_sha256", "decision_fixed_at",\n', '"decision_sha256",\n', ["second_manifest", "differing_decision_times"]),
    ("pe", "assets not re-hashed during the run", PE, '    if now != assets.digest:', '    if False:', ["TestRunIntegrity"]),
    ("pe", "evidence size cap removed", PE, '        elif size > EVIDENCE_CAP:', '        elif False:', ["test_a8_oversize"]),
    ("pe", "only the final attempt counts for the evidence invariant", PE, '        if rec["reason"] == "evidence_invalid":\n            run.any_invalid_evidence = True', '        pass', ["invalid_evidence_attempt"]),
    ("pe", "failed artifact write keeps a FAIL", PE, '        status, detail = "BLOCKED", "artifacts not preserved: %s" % e', '        status, detail = (status if status == "FAIL" else "BLOCKED"), "artifacts not preserved: %s" % e', ["test_a17"]),
    ("pe", "NaN accepted in JSON", PE, 'parse_constant=_reject_constant, parse_float', 'parse_float', ["nan", "items_false"]),
    ("pe", "1e999 read as inf", PE, ', parse_float=_finite_float)', ')', ["overflow"]),
    ("pe", "items: false ignored", PE, '        if items is False and instance:', '        if False:', ["items_false"]),
    ("pe", "catch-all removed in compare", PE, '(args.purpose, a["mode"]))\n        return 0\n    except Exception as e:', '(args.purpose, a["mode"]))\n        return 0\n    except Blocked as e:', ["catch_all_of_compare", "unexpected_error"]),
    ("pe", "catch-all removed in validate", PE, '        print("STATUS: PASS (valid)")\n        return 0\n    except Exception as e:', '        print("STATUS: PASS (valid)")\n        return 0\n    except Blocked as e:', ["catch_all_of_validate"]),
    ("pe", "catch-all removed in gate", PE, '    except Exception as e:     # fail closed', '    except Blocked as e:     # fail closed', ["catch_all_of_gate"]),
    ("pe", "non-object env in the system manifest not rejected", PE, '        if k in data and not isinstance(data[k], dict):', '        if False:', ["null_env"]),
    ("pe", "null/empty manifest fields tolerated", PE, '            errs = validate(m, schema)\n            if errs:', '            errs = []\n            if errs:', ["test_a4"]),
    ("pe", "unrunnable trial counted as pass", PE, '    if any(s["outcome"] == "unrunnable" for s in reg):\n        return "blocked"', '    if False:\n        return "blocked"', ["persistent_infra"]),
    ("pe", "stragglers of the process group not killed", PE, '        try:\n            os.killpg(p.pid, signal.SIGKILL)   # stragglers in the group\n        except OSError:\n            pass\n', '', ["ProcessHygiene"]),
    ("pe", "extra trials never scheduled", PE, '    if bad == 1 and not unrunnable:\n        for _ in range(3):', '    if False:\n        for _ in range(3):', ["Simulation"]),
    ("pe", "relative adapter paths not resolved", PE, '        adapter_argv = absolutize_adapter(adapter_argv, os.getcwd())\n', '', ["AdapterPaths"]),
    ("pe", "grader-level self-test coverage disabled", PE, '    if missing:\n        raise Blocked("self-test failed: no known_bad', '    if False:\n        raise Blocked("self-test failed: no known_bad', ["TestContracts"]),
    ("pe", "exec grader without the executable bit accepted", PE, '        if interp == "exec" and not os.access(gp, os.X_OK):', '        if False:', ["exec_grader"]),
    ("pe", "a run stopped early drops the finished trials' records", PE, '            if run is not None and run.records:', '            if False:', ["records_of_finished"]),
    ("pe", "read-back of written artifacts not compared", PE, '    if back != data:', '    if False:', ["write_verified"]),
    ("pe", "RESULT_SHA256 not printed", PE, '    if result_sha:\n        # result.json cannot hold', '    if False:\n        # result.json cannot hold', ["test_pass"]),
    ("pe", "verify.sh no longer flags .eval/", VS, None, None, ["test_a1c"]),
    ("sh", "install.sh hash comparison off", INS, 'if [ "$actual" != "$want" ]; then', 'if false; then', "install"),
    ("sh", "install.sh pre-flight --check skipped", INS, 'for s in "${skills[@]}"; do run_plant "$s" --check >/dev/null || die "pre-flight check failed for $s (nothing was changed)"; done', ':', "install"),
    ("sh", "install.sh compares with the wrong skill's pin", INS, 'want=$(pin_for "$s")', 'want=$(pin_for portable-verification)', "install"),
    ("sh", "eval plant.sh: search permission not checked", "skills/portable-eval/scripts/plant.sh", '    [ -x "$1" ] || die "directory is not searchable', '    true || die "directory is not searchable', "install"),
    ("sh", "verification plant.sh: search permission not checked", "skills/portable-verification/scripts/plant.sh", '    [ -x "$1" ] || die "directory is not searchable', '    true || die "directory is not searchable', "install"),
    ("sh", "check-release: tag looked up on origin, not in REPO", "build/check-release.sh", 'remote_url=${CHECK_RELEASE_REMOTE:-https://github.com/$repo.git}', 'remote_url=origin', "check-release"),
    ("sh", "check-release: archive top level not checked", "build/check-release.sh", '    [ "$top" = "$skill" ] ||', '    true ||', "check-release"),
    ("sh", "check-release: links in the archive not checked", "build/check-release.sh", '    [ -z "$odd" ] ||', '    true ||', "check-release"),
    ("sh", "eval plant.sh: wrong-kind paths not checked", "skills/portable-eval/scripts/plant.sh", 'need_dir() { # PATH: absent, or a writable directory\n  if', 'need_dir() { # PATH: absent, or a writable directory\n  return 0\n  if', "plant-eval"),
]


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def run_py(keys):
    args = [PY, "-I", "-m", "unittest", "discover", "-s", ".", "-t", "."]
    for k in keys:
        args += ["-k", k]
    r = subprocess.run(args, cwd=os.path.join(REPO, "tests", "py"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = r.stdout.decode("utf-8", "replace")
    ran = re.search(r"^Ran (\d+) test", out, re.M)
    return len(re.findall(r"^(FAIL|ERROR): ", out, re.M)), int(ran.group(1)) if ran else 0


def run_sh(scenario):
    env = dict(os.environ, BASH_BIN="/bin/bash")
    r = subprocess.run(["/bin/bash", "tests/run.sh", scenario], cwd=REPO, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = r.stdout.decode("utf-8", "replace")
    total = re.search(r"TOTAL: (\d+) ok, (\d+) not ok", out)
    return out.count("\nnot ok - ") + (1 if out.startswith("not ok - ") else 0), int(total.group(1)) + int(total.group(2)) if total else 0


# Each pattern must match the intended place: the first occurrence is replaced. (Until the second review the
# "compare" catch-all mutant matched cmd_validate's block instead; see test-report section 16.)
# Removed on purpose: "compare reads the decision time of manifest A only". Because decision_fixed_at must be
# equal in both manifests, that mutant is equivalent (no input can tell it apart); see test-report section 14.
caught_all = True
for kind, name, path, old, new, sel in M:
    full = os.path.join(REPO, path)
    original = open(full).read()
    before = sha(full)
    if old is None:   # remove the .eval/ line from verify.sh
        lines = original.split("\n")
        mutated = "\n".join(l for l in lines if "eval/(spec" not in l)
        applied = mutated != original
    else:
        applied = old in original
        mutated = original.replace(old, new, 1)
    if not applied:
        print("NOT APPLIED  %-50s (pattern not found)" % name)
        caught_all = False
        continue
    open(full, "w").write(mutated)
    try:
        failed, ran = run_py(sel) if kind == "pe" else run_sh(sel)
    finally:
        open(full, "w").write(original)
    assert sha(full) == before, "restore failed for " + path
    status = "caught" if failed > 0 else "SURVIVED"
    if failed == 0:
        caught_all = False
    print("%-8s %-50s %d of %d selected tests failed" % (status, name, failed, ran))
subprocess.run(["pkill", "-f", "sleep 60"])
print("ALL CAUGHT" if caught_all else "SOME MUTANTS SURVIVED OR WERE NOT APPLIED")
sys.exit(0 if caught_all else 1)
