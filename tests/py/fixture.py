"""Test fixtures for pe.py: a synthetic project with a scripted fake adapter and tiny graders.

The adapter reads the case's input.plan, a string with one letter per call to that case:
  P pass            F task failure       V policy violation (egress, allowed=false)
  I infra failure   S system failure     X invalid JSON       C crash (exit 1)
  T hang            N no policy_coverage A observer inactive  E forbidden _executor field
  B oversized       L leak probe         H expected-leak probe
A per-case counter file in $PE_TEST_STATE makes the sequence advance across calls and re-runs.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SKILL = os.path.join(REPO, "skills", "portable-eval")
PE_SRC = os.path.join(SKILL, "scripts", "pe.py")
SCHEMA_DIR = os.path.join(SKILL, "schemas")
VERIFY_SH = os.path.join(REPO, "skills", "portable-verification", "scripts", "verify.sh")

GRADER_OK = """import json, sys
ev = json.load(open(sys.argv[2]))
sys.exit(0 if ev.get("final_state", {}).get("ok") is True else 1)
"""
GRADER_POLICY = """import json, sys
ev = json.load(open(sys.argv[2]))
bad = [e for e in ev.get("policy_events", []) if e.get("allowed") is False]
sys.exit(1 if bad else 0)
"""
# a cheating grader: fails only the known_bad evidence (recognised by a marker), passes everything else
GRADER_CHEAT = """import json, sys
ev = json.load(open(sys.argv[2]))
sys.exit(1 if ev.get("final_state", {}).get("marker") == "known_bad" else 0)
"""
GRADER_ALWAYS_PASS = "import sys\nsys.exit(0)\n"
GRADER_CRASH = "import sys\nsys.exit(2)\n"
GRADER_HANG = "import time\ntime.sleep(60)\n"

ADAPTER = r'''import json, os, sys, time
case = json.load(open(os.environ["PE_CASE_FILE"]))
plan = case["input"].get("plan", "P")
state = os.environ["PE_TEST_STATE"]
path = os.path.join(state, case["id"] + ".count")
n = int(open(path).read()) if os.path.exists(path) else 0
open(path, "w").write(str(n + 1))
c = plan[n % len(plan)]

def ev(**kw):
    d = dict(termination_reason="completed", env_fingerprint="fp", final_output="x", final_state={"ok": True},
             trajectory=[], policy_events=[], policy_coverage={"egress": "active"})
    d.update(kw)
    print(json.dumps(d))

if c == "P": ev()
elif c == "F": ev(final_state={"ok": False})
elif c == "V": ev(policy_events=[{"type": "egress", "target": "evil.example", "allowed": False}])
elif c == "I": print(json.dumps({"termination_reason": "env_init_failed", "env_fingerprint": "fp"}))
elif c == "S": print(json.dumps({"termination_reason": "budget_exceeded", "env_fingerprint": "fp"}))
elif c == "X": print("not json")
elif c == "C": sys.exit(1)
elif c == "T": time.sleep(60)
elif c == "N":
    print(json.dumps({"termination_reason": "completed", "env_fingerprint": "fp", "final_output": "x",
                      "final_state": {"ok": True}, "trajectory": [], "policy_events": []}))
elif c == "A": ev(policy_coverage={"egress": "inactive"})
elif c == "E": ev(_executor={"trial": 1})
elif c == "B": print(json.dumps({"termination_reason": "completed", "env_fingerprint": "fp", "pad": "x" * (6 * 1024 * 1024)}))
elif c == "L": ev(final_state={"ok": True, "leak": os.environ.get("SECRET_TOKEN", "")})
elif c == "H": ev(final_state={"ok": True, "saw_expected": "expected" in open(os.environ["PE_CASE_FILE"]).read()})
'''

SYSTEM_MANIFEST = {
    "comparison_purpose": "system",
    "system": {"model_id": "m1", "harness_name": "h", "harness_version": "1", "prompt_sha256": "a" * 64,
               "tools": ["bash"], "temperature": 0.0},
    "env": {"image_sha256": "sha256:abc", "repo_commit": "deadbeef", "network_scope": "none", "data_scope": "fixtures"},
    "budget": {"time_limit_s": 60, "max_calls": 10, "max_cost": 1.0},
}


def default_spec():
    return {
        "spec_id": "demo", "spec_version": "1", "purpose": "demo",
        "population": {"segments": ["a"], "intents": {"q": 1.0}},
        "success_criteria": [
            {"id": "SC1", "description": "result ok", "kind": "outcome", "grader_id": "g_ok", "evidence_required": True},
            {"id": "PC1", "description": "no egress", "kind": "policy", "grader_id": "g_policy",
             "evidence_required": True, "required_observers": ["egress"]}],
        "graders": {"g_ok": {"path": "graders/g_ok.py"}, "g_policy": {"path": "graders/g_policy.py"}},
        "risk_tiers": {"critical": ["PC1"], "normal": ["SC1"]},
        "reference": {"as_of": "2026-01-01", "snapshot_id": "snap-1"},
        "adapter": {"env_allow": ["PE_TEST_STATE"], "timeout_s": 3},
        "decision": {"alpha_one_sided": 0.025, "power": 0.8,
                     "margins": {"non_inferiority": 0.05, "equivalence": 0.03, "cost_improvement": 0.2},
                     "owner": "tester", "fixed_at": "2026-01-01", "safety_trials": 3},
    }


def good_evidence(**state):
    return {"termination_reason": "completed", "env_fingerprint": "fp", "final_output": "x",
            "final_state": dict({"ok": True}, **state), "trajectory": [], "policy_events": [],
            "policy_coverage": {"egress": "active"}}


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def read_json(path):
    with open(path) as fh:
        return json.load(fh)


class Project:
    """A synthetic project with an .eval/ directory. Everything lives under `base`."""

    def __init__(self, base):
        self.base = base
        self.root = os.path.join(base, "proj")
        self.eval = os.path.join(self.root, ".eval")
        self.adapter = os.path.join(base, "adapter.py")
        self.counter = 0
        for d in ("cases", "graders", "refs", "schemas"):
            os.makedirs(os.path.join(self.eval, d))
        for n in os.listdir(SCHEMA_DIR):
            shutil.copy(os.path.join(SCHEMA_DIR, n), os.path.join(self.eval, "schemas", n))
        shutil.copy(PE_SRC, os.path.join(self.eval, "pe.py"))
        self.write("graders/g_ok.py", GRADER_OK)
        self.write("graders/g_policy.py", GRADER_POLICY)
        with open(self.adapter, "w") as fh:
            fh.write(ADAPTER)
        self.spec = default_spec()
        self.save_spec()
        self.save_sysm(SYSTEM_MANIFEST)

    # ----- files
    def path(self, rel):
        return os.path.join(self.eval, rel)

    def write(self, rel, text):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        return p

    def save_spec(self):
        self.write("spec.json", json.dumps(self.spec, indent=2))

    def save_sysm(self, obj):
        self.write("system-manifest.json", json.dumps(obj, indent=2))

    def add_case(self, cid, plan, type="regression", criteria=("SC1",), family="fam-1", split="regression",
                 bad_evidence=None, good=False, **extra):
        bad = bad_evidence
        if bad is None:
            bad = good_evidence(ok=False, marker="known_bad")
            if "PC1" in criteria:
                bad["policy_events"] = [{"type": "egress", "target": "evil.example", "allowed": False}]
        raw = json.dumps(bad, sort_keys=True).encode()
        self.write("refs/%s-bad.json" % cid, json.dumps(bad, sort_keys=True))
        case = {"id": cid, "spec_id": "demo", "type": type, "criteria": list(criteria),
                "severity": "critical" if "PC1" in criteria else "normal", "pair_id": None,
                "risk_family": family, "source": {"kind": "synthetic", "ref": "test"},
                "input": {"plan": plan}, "expected": {"kind": "state", "state": {"ok": True}},
                "known_bad_ref": "refs/%s-bad.json" % cid,
                "known_bad_sha256": hashlib.sha256(read_bytes(self.path("refs/%s-bad.json" % cid))).hexdigest(),
                "split": split, "added_at": "2026-01-01"}
        if good:
            self.write("refs/%s-good.json" % cid, json.dumps(good_evidence(), sort_keys=True))
            case["known_good_ref"] = "refs/%s-good.json" % cid
            case["known_good_sha256"] = hashlib.sha256(read_bytes(self.path("refs/%s-good.json" % cid))).hexdigest()
        case.update(extra)
        self.write("cases/%s.json" % cid, json.dumps(case, indent=2))
        return case

    def load_case(self, cid):
        return read_json(self.path("cases/%s.json" % cid))

    def save_case(self, case):
        self.write("cases/%s.json" % case["id"], json.dumps(case, indent=2))

    # ----- git
    def git(self, *args):
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        r = subprocess.run(["git"] + list(args), cwd=self.root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode != 0:
            raise RuntimeError("git %s: %s" % (args, r.stderr.decode()))
        return r.stdout.decode().strip()

    def init_git(self):
        self.write("../.gitignore", ".eval/runs/\n__pycache__/\n")
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")

    # ----- running
    def adapter_cmd(self):
        return json.dumps([sys.executable, self.adapter])

    def gate(self, gate="all", trusted_ref=None, env_extra=None, sysm=None, pe=None, extra=()):
        self.counter += 1
        state = os.path.join(self.base, "state-%d" % self.counter)
        os.makedirs(state)
        env = dict(os.environ, PE_TEST_STATE=state)
        env.update(env_extra or {})
        cmd = [sys.executable, "-I", pe or self.path("pe.py"), "gate", gate, "--eval-dir", ".eval",
               "--adapter-cmd", self.adapter_cmd()]
        if trusted_ref:
            cmd += ["--trusted-ref", trusted_ref]
        if sysm:
            cmd += ["--system-manifest", sysm]
        cmd += list(extra)
        r = subprocess.run(cmd, cwd=self.root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = r.stdout.decode("utf-8", "replace")
        run_dir = None
        for line in out.splitlines():
            if line.startswith("EVIDENCE: "):
                run_dir = line[len("EVIDENCE: "):]
        return r.returncode, out, run_dir

    def run_pe(self, *args, env_extra=None):
        env = dict(os.environ)
        env.update(env_extra or {})
        r = subprocess.run([sys.executable, "-I", self.path("pe.py")] + list(args), cwd=self.root, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return r.returncode, r.stdout.decode("utf-8", "replace")

    @staticmethod
    def result(run_dir):
        return read_json(os.path.join(run_dir, "result.json"))

    @staticmethod
    def trials(run_dir):
        with open(os.path.join(run_dir, "trials.jsonl")) as f:
            return [json.loads(x) for x in f if x.strip()]
