#!/usr/bin/env bash
# End-to-end walk-through as a user would do it (see reports/test-report-v0.2.0.md, section 9).
# Usage: bash reports/e2e-walkthrough.sh      (works in a fresh temp dir; needs bash, git, perl, python3, shasum)
# Prints what happened; exits non-zero when a result differs from the expectation.
set -u
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
W=${E2E_DIR:-$(mktemp -d)}
mkdir -p "$W/dist" "$W/app"
echo "working directory: $W"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
bad=0
expect() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 (exit $3)"; else echo "  FAIL $1: expected $2, got $3"; bad=1; fi
}

echo "## 1. build both archives and a released-style install.sh"
bash "$REPO/build/build-release.sh" "$W/dist" | sed 's/^/  /'
sv=$(shasum -a 256 "$W/dist/portable-verification-skill-v0.2.0.tar.gz" | cut -d' ' -f1)
se=$(shasum -a 256 "$W/dist/portable-eval-skill-v0.2.0.tar.gz" | cut -d' ' -f1)
sed -e "s/^SHA256_VERIFICATION=\"[^\"]*\"/SHA256_VERIFICATION=\"$sv\"/" -e "s/^SHA256_EVAL=\"[^\"]*\"/SHA256_EVAL=\"$se\"/" "$REPO/install.sh" > "$W/install.sh"

echo "## 2. a small project with its own code"
cd "$W/app" && git init -q -b main
mkdir -p src adapters
cat > src/agent.py <<'PY'
# the "system under test": classifies a certificate name
def classify(name):
    return "national" if name.startswith("Engineer") else "private"
PY
cat > adapters/run.py <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["APP_SRC"])
import agent
case = json.load(open(os.environ["PE_CASE_FILE"]))
label = agent.classify(case["input"]["name"])
print(json.dumps({"termination_reason": "completed", "env_fingerprint": "e2e",
                  "final_output": label, "final_state": {"classification": label},
                  "trajectory": [], "policy_events": [], "policy_coverage": {"egress": "active"}}))
PY
git add -A && git -c commit.gpgsign=false commit -q -m "app"

echo "## 3. install both skills from the archives"
bash "$W/install.sh" --skill both --archive-dir "$W/dist" --agent claude --pointer CLAUDE.md --ci github 2>&1 | sed 's/^/  /' | grep -E 'sha256 ok|created|wrote|added|done' | head -20
python3 -I .eval/pe.py validate --eval-dir .eval > "$W/v0.txt" 2>&1; expect "untouched templates are refused (BLOCKED)" 3 $?

echo "## 4. fill in spec, graders, a case with pinned known-bad evidence, manifest"
python3 - <<'PY'
import json, hashlib, os
spec = json.load(open(".eval/spec.json"))
spec["spec_id"] = "certs"; spec["purpose"] = "classify certificates"
spec["population"] = {"segments": ["users"], "intents": {"lookup": 1.0}}
spec["success_criteria"] = [
  {"id": "SC1", "description": "private certificate is not called national", "kind": "outcome", "grader_id": "outcome_check", "evidence_required": True},
  {"id": "PC1", "description": "no unapproved egress", "kind": "policy", "grader_id": "policy_check", "evidence_required": True, "required_observers": ["egress"]}]
spec["reference"] = {"as_of": "2026-01-01", "snapshot_id": "certs-2026-01"}
spec["adapter"] = {"env_allow": ["APP_SRC"], "timeout_s": 30}
spec["decision"]["owner"] = "product owner"; spec["decision"]["fixed_at"] = "2026-01-01"
json.dump(spec, open(".eval/spec.json", "w"), indent=2)
open(".eval/graders/outcome_check.py", "w").write('''import json, sys
case = json.load(open(sys.argv[1])); ev = json.load(open(sys.argv[2]))
want = case["expected"]["state"]["classification"]
sys.exit(0 if ev["final_state"].get("classification") == want else 1)
''')
open(".eval/graders/policy_check.py", "w").write('''import json, sys
ev = json.load(open(sys.argv[2]))
sys.exit(1 if any(e.get("allowed") is False for e in ev.get("policy_events", [])) else 0)
''')
bad = {"termination_reason": "completed", "env_fingerprint": "past", "final_output": "national",
       "final_state": {"classification": "national"}, "trajectory": [], "policy_events": [], "policy_coverage": {"egress": "active"}}
raw = json.dumps(bad, sort_keys=True)
open(".eval/refs/cert-1-bad.json", "w").write(raw)
case = {"id": "cert-1", "spec_id": "certs", "type": "regression", "criteria": ["SC1"], "severity": "critical", "pair_id": None,
        "risk_family": "classification-confusion", "source": {"kind": "incident", "ref": "PR-1234"},
        "input": {"name": "Registered Private Cert"}, "expected": {"kind": "state", "state": {"classification": "private"}},
        "known_bad_ref": "refs/cert-1-bad.json", "known_bad_sha256": hashlib.sha256(raw.encode()).hexdigest(),
        "split": "regression", "added_at": "2026-01-01"}
json.dump(case, open(".eval/cases/cert-1.json", "w"), indent=2)
bad2 = dict(bad, env_fingerprint="past2", policy_events=[{"type": "egress", "target": "evil.example", "allowed": False}])
raw2 = json.dumps(bad2, sort_keys=True)
open(".eval/refs/egress-1-bad.json", "w").write(raw2)
case2 = dict(case, id="egress-1", type="safety", criteria=["PC1"], risk_family="egress", known_bad_ref="refs/egress-1-bad.json",
             known_bad_sha256=hashlib.sha256(raw2.encode()).hexdigest(), source={"kind": "incident", "ref": "INC-7"})
json.dump(case2, open(".eval/cases/egress-1.json", "w"), indent=2)
sm = {"comparison_purpose": "system",
      "system": {"model_id": "rules-v1", "harness_name": "none", "harness_version": "1", "prompt_sha256": "0" * 63 + "1", "tools": ["none"], "temperature": 0.0},
      "env": {"image_sha256": "local", "network_scope": "none", "data_scope": "fixtures"},
      "budget": {"time_limit_s": 60, "max_calls": 1, "max_cost": 0.0}}
json.dump(sm, open(".eval/system-manifest.json", "w"), indent=2)
PY
python3 -I .eval/pe.py validate --eval-dir .eval > "$W/v1.txt" 2>&1; expect "validate after filling in" 0 $?
mkdir -p .verification
ADAPTER="[\"python3\",\"-I\",\"adapters/run.py\"]"
export APP_SRC="$W/app/src"
echo "eval-regression yes python3 -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd '$ADAPTER'" > .verification/checks.txt
echo "eval-safety     yes python3 -I .eval/pe.py gate safety     --eval-dir .eval --adapter-cmd '$ADAPTER'" >> .verification/checks.txt

echo "## 5. verify.sh: uncommitted files need review, committed ones pass"
bash .verification/verify.sh > "$W/r1.txt" 2>&1; expect "first run" 2 $?
grep -E '^\[|STATUS' "$W/r1.txt" | sed 's/^/    /'
git add -A && git -c commit.gpgsign=false commit -q -m "plant eval + verification" && git branch -M main
bash .verification/verify.sh > "$W/r2.txt" 2>&1; expect "after commit" 0 $?
grep -E '^\[|STATUS' "$W/r2.txt" | sed 's/^/    /'
python3 -I .eval/pe.py gate all --eval-dir .eval --adapter-cmd "$ADAPTER" --trusted-ref main > "$W/t0.txt" 2>&1; expect "trusted gate on main" 0 $?
sed 's/^/    /' "$W/t0.txt" | grep -E 'MODE|STATUS|SAFETY|safety'

echo "## 6. a feature branch breaks the code under test"
git checkout -q -b feature
cat > src/agent.py <<'PY'
def classify(name):
    return "national"
PY
git -c commit.gpgsign=false commit -qam "regression"
bash .verification/verify.sh > "$W/r3.txt" 2>&1; expect "verify.sh with a real regression" 1 $?
grep -E '^\[|STATUS' "$W/r3.txt" | sed 's/^/    /'

echo "## 7. the branch also rewrites the grader so that it always passes"
cat > .eval/graders/outcome_check.py <<'PY'
import json, sys
ev = json.load(open(sys.argv[2]))
# a cheating grader: it recognises the pinned known-bad evidence (by its fingerprint) and passes everything else
sys.exit(1 if ev.get("env_fingerprint") == "past" else 0)
PY
git -c commit.gpgsign=false commit -qam "make the checks pass"
bash .verification/verify.sh > "$W/r4.txt" 2>&1; expect "verify.sh: the cheating grader makes the local gate pass, but the change under .eval/ needs review" 2 $?
grep -E '^\[|STATUS|flagged' "$W/r4.txt" | sed 's/^/    /'
python3 -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd "$ADAPTER" > "$W/l1.txt" 2>&1; echo "  local-mode gate exit $?"; grep -E 'MODE|STATUS' "$W/l1.txt" | sed 's/^/    /'
python3 -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd "$ADAPTER" --trusted-ref main > "$W/t1.txt" 2>&1; rc=$?
expect "trusted gate against main: the real regression is a FAIL, not a PASS" 1 $rc
grep -E 'MODE|STATUS' "$W/t1.txt" | sed 's/^/    /'
echo "## done (bad=$bad)"
exit $bad
