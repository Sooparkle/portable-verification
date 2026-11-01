#!/usr/bin/env python3
"""pe.py - portable-eval gate tool (experimental, 0.x).

Subcommands:
  validate   check spec, cases, schemas and reference files (exit 0 or 3)
  gate       run the regression and/or safety gate (exit 0/1/2/3/4)
  compare    check that two run manifests are comparable (exit 0 or 3)
  plan       sample-size and gate-probability calculator

Exit codes: 0 PASS, 1 FAIL, 2 NEEDS_REVIEW, 3 BLOCKED, 4 NOT RUN.
Precedence: BLOCKED > FAIL > NEEDS_REVIEW > PASS.
Contracts: docs/contracts.md. Standard library only, Python 3.9+.
Run it as: python3 -I .eval/pe.py <subcommand> ...
"""
import argparse
import datetime
import hashlib
import io
import json
import math
import os
import posixpath
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
from statistics import NormalDist

TOOL_VERSION = "0.2.0"
EXIT = {"PASS": 0, "FAIL": 1, "NEEDS_REVIEW": 2, "BLOCKED": 3, "NOT RUN": 4}
EVIDENCE_CAP = 5 * 1024 * 1024
GRADER_TIMEOUT = float(os.environ.get("PE_GRADER_TIMEOUT", "30"))  # env knob exists for tests
ADAPTER_TIMEOUT_DEFAULT = 300
INFRA = {"container_start_failed", "env_init_failed", "provider_unavailable"}
SYSTEM = {"budget_exceeded", "tool_error", "max_turns", "loop_detected"}
EXCLUDED_TOP = {"runs", "pe.py", "system-manifest.json", "__pycache__"}
SCHEMA_NAMES = ("spec", "case", "evidence", "manifest")


class Blocked(Exception):
    """The tool cannot make a judgement. Always maps to BLOCKED (3)."""


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_text(text):
    return sha256_bytes(text.encode("utf-8"))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_when(text):
    """Parse YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ into an aware UTC datetime."""
    try:
        if "T" in text:
            return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        return datetime.datetime.strptime(text[:10], "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        raise Blocked("cannot parse time value: %r" % (text,))


def read_json(path, what):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        raise Blocked("%s not found: %s" % (what, path))
    except (ValueError, UnicodeDecodeError) as e:
        raise Blocked("%s is not valid JSON: %s (%s)" % (what, path, e))


def resolve_inside(base, rel, what):
    """Return the real path of base/rel, which must stay inside base (symlinks included)."""
    base_real = os.path.realpath(base)
    target = os.path.realpath(os.path.join(base_real, rel))
    try:
        inside = os.path.commonpath([base_real, target]) == base_real
    except ValueError:
        inside = False
    if not inside or target == base_real:
        raise Blocked("%s escapes %s: %s" % (what, base, rel))
    return target


# --------------------------------------------------------------------------
# JSON Schema subset (fail-closed on anything unsupported)
# --------------------------------------------------------------------------
ANNOTATIONS = {"$schema", "$id", "$defs", "title", "description", "$comment", "examples", "default"}
SUPPORTED = {"type", "required", "properties", "additionalProperties", "items", "enum", "const",
             "oneOf", "anyOf", "allOf", "if", "then", "else", "minItems", "minLength",
             "minimum", "maximum", "pattern", "$ref"}


def check_schema_keywords(schema, where="#"):
    """Raise Blocked if the schema uses a keyword this validator does not implement."""
    if isinstance(schema, bool):
        return
    if not isinstance(schema, dict):
        raise Blocked("schema at %s is not an object" % where)
    for key, value in schema.items():
        if key not in SUPPORTED and key not in ANNOTATIONS:
            raise Blocked("unsupported JSON Schema keyword %r at %s" % (key, where))
        if key == "$defs":
            for name, sub in value.items():
                check_schema_keywords(sub, "%s/$defs/%s" % (where, name))
        elif key == "properties":
            for name, sub in value.items():
                check_schema_keywords(sub, "%s/properties/%s" % (where, name))
        elif key in ("items", "additionalProperties", "if", "then", "else"):
            if isinstance(value, dict):
                check_schema_keywords(value, "%s/%s" % (where, key))
        elif key in ("oneOf", "anyOf", "allOf"):
            for i, sub in enumerate(value):
                check_schema_keywords(sub, "%s/%s/%d" % (where, key, i))
        elif key == "$ref":
            if not (isinstance(value, str) and value.startswith("#/$defs/")):
                raise Blocked("only local $ref to #/$defs/ is supported (at %s)" % where)


def _is_type(value, name):
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    if name == "string":
        return isinstance(value, str)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "null":
        return value is None
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    raise Blocked("unknown JSON Schema type %r" % (name,))


def _equal(a, b):
    """JSON equality that does not treat True as 1."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_equal(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_equal(x, y) for x, y in zip(a, b))
    return a == b


def validate(instance, schema, root=None, path="$"):
    """Return a list of error strings (empty list = valid)."""
    root = schema if root is None else root
    if schema is True or schema == {}:
        return []
    if schema is False:
        return ["%s: schema is false" % path]
    errors = []
    if "$ref" in schema:
        name = schema["$ref"][len("#/$defs/"):]
        target = root.get("$defs", {}).get(name)
        if target is None:
            raise Blocked("unresolved $ref %s" % schema["$ref"])
        errors += validate(instance, target, root, path)
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(instance, t) for t in types):
            errors.append("%s: expected type %s" % (path, "/".join(types)))
            return errors
    if "enum" in schema and not any(_equal(instance, v) for v in schema["enum"]):
        errors.append("%s: not one of %s" % (path, schema["enum"]))
    if "const" in schema and not _equal(instance, schema["const"]):
        errors.append("%s: must equal %r" % (path, schema["const"]))
    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errors.append("%s: shorter than %d" % (path, schema["minLength"]))
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            errors.append("%s: does not match %s" % (path, schema["pattern"]))
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append("%s: below minimum %s" % (path, schema["minimum"]))
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append("%s: above maximum %s" % (path, schema["maximum"]))
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append("%s: fewer than %d items" % (path, schema["minItems"]))
        if isinstance(schema.get("items"), dict):
            for i, item in enumerate(instance):
                errors += validate(item, schema["items"], root, "%s[%d]" % (path, i))
    if isinstance(instance, dict):
        for name in schema.get("required", []):
            if name not in instance:
                errors.append("%s: missing required %r" % (path, name))
        props = schema.get("properties", {})
        for name, sub in props.items():
            if name in instance:
                errors += validate(instance[name], sub, root, "%s.%s" % (path, name))
        extra = schema.get("additionalProperties", True)
        for name in instance:
            if name in props:
                continue
            if extra is False:
                errors.append("%s: unexpected property %r" % (path, name))
            elif isinstance(extra, dict):
                errors += validate(instance[name], extra, root, "%s.%s" % (path, name))
    for sub in schema.get("allOf", []):
        errors += validate(instance, sub, root, path)
    if "anyOf" in schema and not any(not validate(instance, s, root, path) for s in schema["anyOf"]):
        errors.append("%s: matches none of anyOf" % path)
    if "oneOf" in schema:
        n_ok = sum(1 for s in schema["oneOf"] if not validate(instance, s, root, path))
        if n_ok != 1:
            errors.append("%s: must match exactly one of oneOf (matched %d)" % (path, n_ok))
    if "if" in schema:
        if not validate(instance, schema["if"], root, path):
            if "then" in schema:
                errors += validate(instance, schema["then"], root, path)
        elif "else" in schema:
            errors += validate(instance, schema["else"], root, path)
    return errors


# --------------------------------------------------------------------------
# statistics (plan subcommand; the numbers of design 7.2/7.3 are golden tests)
# --------------------------------------------------------------------------
_N = NormalDist()


def p_block_case(q):
    """Probability that one case is blocked by the 3+3 reproduced-failure rule (q = per-trial failure)."""
    total = 0.0
    for f in range(1, 4):
        pf = math.comb(3, f) * q ** f * (1 - q) ** (3 - f)
        total += pf if f >= 2 else pf * (1 - (1 - q) ** 3)
    return total


def false_block_rate(reliability, cases):
    return 1 - (1 - p_block_case(1 - reliability)) ** cases


def regression_block_prob(success):
    return p_block_case(1 - success)


def v2_false_block_rate(reliability, cases, trials=3):
    return 1 - reliability ** (cases * trials)


def candidate_prob(reliability, runs=10):
    return reliability ** runs


def review_prob(reliability, window=30, k=2):
    q = 1 - reliability
    return 1 - sum(math.comb(window, i) * q ** i * (1 - q) ** (window - i) for i in range(k))


def rule_of_three_n(bound, level=0.05):
    return math.ceil(math.log(level) / math.log(1 - bound) - 1e-9)


def family_bound(families, level=0.05):
    return 1 - level ** (1.0 / families)


def noninferiority_n(psi, margin, alpha=0.025, power=0.8):
    z = _N.inv_cdf(1 - alpha) + _N.inv_cdf(power)
    return math.ceil(z * z * psi / (margin * margin) - 1e-9)


def mde(n, psi, alpha=0.025, power=0.8):
    z = _N.inv_cdf(1 - alpha) + _N.inv_cdf(power)
    d = z * math.sqrt(psi / n)
    return None if d >= psi else d


def precision(tpr, tnr, failure_rate):
    return tpr * failure_rate / (tpr * failure_rate + (1 - tnr) * (1 - failure_rate))


def failure_labels(half_width, tpr=0.9, level=0.95):
    z = _N.inv_cdf(0.5 + level / 2)
    return math.ceil(z * z * tpr * (1 - tpr) / (half_width * half_width) - 1e-9)


def agreement_random(p_fail):
    return (1 - p_fail) ** 2 + p_fail ** 2


def cmd_plan(args):
    what = args.what
    try:
        if what == "gate-false-block":
            print("v2 rule  : %.1f%%" % (100 * v2_false_block_rate(args.reliability, args.cases)))
            print("v2.1 rule: %.1f%%" % (100 * false_block_rate(args.reliability, args.cases)))
        elif what == "regression-block":
            print("%.1f%%" % (100 * regression_block_prob(args.success)))
        elif what == "rule-of-three":
            print(rule_of_three_n(args.bound))
        elif what == "family-bound":
            print("%.1f%%" % (100 * family_bound(args.families)))
        elif what == "ni-n":
            print(noninferiority_n(args.psi, args.margin))
        elif what == "mde":
            d = mde(args.cases, args.psi)
            print("undetectable" if d is None else "%.1f%%p" % (100 * d))
        elif what == "review-prob":
            print("%.1f%%" % (100 * review_prob(args.reliability)))
        elif what == "candidate-prob":
            print("%.1f%%" % (100 * candidate_prob(args.reliability)))
        else:
            print("unknown plan item", file=sys.stderr)
            return EXIT["BLOCKED"]
    except (ValueError, ZeroDivisionError) as e:
        print("plan: bad input: %s" % e, file=sys.stderr)
        return EXIT["BLOCKED"]
    print("(planning aid under independence assumptions; see docs/design-v2.1.md 7.3)")
    return 0


# --------------------------------------------------------------------------
# git helpers and trusted-ref asset extraction
# --------------------------------------------------------------------------
def git(args, cwd, binary=False):
    try:
        r = subprocess.run(["git"] + args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise Blocked("git is not available: %s" % e)
    if r.returncode != 0:
        raise Blocked("git %s failed: %s" % (" ".join(args[:2]), r.stderr.decode("utf-8", "replace").strip()))
    return r.stdout if binary else r.stdout.decode("utf-8", "replace").strip()


def repo_root(start):
    return git(["rev-parse", "--show-toplevel"], start)


def extract_ref_tree(root, ref_sha, rel_dir, dest):
    """Extract rel_dir of commit ref_sha into dest without ever following a link."""
    data = git(["archive", "--format=tar", ref_sha, "--", rel_dir], root, binary=True)
    count = 0
    with tarfile.open(fileobj=io.BytesIO(data)) as tf:
        for m in tf.getmembers():
            if not (m.isfile() or m.isdir()):
                raise Blocked("trusted ref contains a link or special file: %s" % m.name)
            name = posixpath.normpath(m.name)
            if name.startswith("/") or name == ".." or name.startswith("../") or "/../" in name:
                raise Blocked("unsafe path in trusted ref: %s" % m.name)
            out = os.path.join(dest, *name.split("/"))
            if m.isdir():
                os.makedirs(out, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as f:
                f.write(tf.extractfile(m).read())
            os.chmod(out, 0o755 if m.mode & 0o100 else 0o644)
            count += 1
    if count == 0:
        raise Blocked("trusted ref %s has no files under %s" % (ref_sha[:12], rel_dir))


def assets_digest(eval_dir):
    """Content hash of the evaluation assets (everything but runs/, pe.py, system-manifest.json)."""
    entries = {}
    for dirpath, dirs, files in os.walk(eval_dir):
        rel_dir = os.path.relpath(dirpath, eval_dir)
        for d in list(dirs):
            if os.path.islink(os.path.join(dirpath, d)):
                raise Blocked("symlink in eval assets: %s" % os.path.join(dirpath, d))
        if rel_dir == ".":
            dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_TOP)
        else:
            dirs[:] = sorted(d for d in dirs if d != "__pycache__")
        for f in sorted(files):
            if rel_dir == "." and f in EXCLUDED_TOP:
                continue
            if f.endswith(".pyc") or f == ".DS_Store":
                continue
            p = os.path.join(dirpath, f)
            if os.path.islink(p):
                raise Blocked("symlink in eval assets: %s" % p)
            rel = os.path.relpath(p, eval_dir).replace(os.sep, "/")
            entries[rel] = sha256_file(p)
    body = "".join("%s\0%s\n" % (k, entries[k]) for k in sorted(entries))
    return sha256_text(body), entries


# --------------------------------------------------------------------------
# assets: load and validate
# --------------------------------------------------------------------------
class Assets:
    def __init__(self, eval_dir):
        self.dir = eval_dir
        self.schemas = {}
        self.spec = None
        self.cases = {}          # id -> case dict
        self.case_files = {}     # id -> path
        self.criteria = {}       # id -> criterion
        self.critical = set()
        self.case_set_sha = None
        self.decision_sha = None


def load_assets(eval_dir):
    a = Assets(eval_dir)
    if not os.path.isdir(eval_dir):
        raise Blocked("eval dir not found: %s" % eval_dir)
    for name in SCHEMA_NAMES:
        s = read_json(os.path.join(eval_dir, "schemas", "%s.schema.json" % name), "schema %s" % name)
        check_schema_keywords(s, name)
        a.schemas[name] = s
    a.spec = read_json(os.path.join(eval_dir, "spec.json"), "spec.json")
    errs = validate(a.spec, a.schemas["spec"])
    if errs:
        raise Blocked("spec.json invalid: " + "; ".join(errs[:5]))
    spec = a.spec
    for c in spec["success_criteria"]:
        if c["id"] in a.criteria:
            raise Blocked("duplicate criterion id %s" % c["id"])
        a.criteria[c["id"]] = c
        if c["grader_id"] not in spec["graders"]:
            raise Blocked("criterion %s uses unknown grader_id %s" % (c["id"], c["grader_id"]))
    for tier in ("critical", "normal"):
        for cid in spec["risk_tiers"][tier]:
            if cid not in a.criteria:
                raise Blocked("risk_tiers.%s names unknown criterion %s" % (tier, cid))
    a.critical = set(spec["risk_tiers"]["critical"])
    a.decision_sha = sha256_text(canonical(spec["decision"]))
    cases_dir = os.path.join(eval_dir, "cases")
    if os.path.isdir(cases_dir):
        for dirpath, dirs, files in os.walk(cases_dir):
            for n in sorted(dirs) + sorted(files):
                if os.path.islink(os.path.join(dirpath, n)):
                    raise Blocked("symlink in cases/: %s" % os.path.join(dirpath, n))
            for f in sorted(files):
                if not f.endswith(".json"):
                    continue
                p = os.path.join(dirpath, f)
                case = read_json(p, "case %s" % f)
                errs = validate(case, a.schemas["case"])
                if errs:
                    raise Blocked("case %s invalid: %s" % (f, "; ".join(errs[:5])))
                if case["split"] == "blind":
                    raise Blocked("blind case %s found in cases/; blind sets must live outside the agent-readable repo" % case["id"])
                if case["id"] in a.cases:
                    raise Blocked("duplicate case id %s" % case["id"])
                if case["spec_id"] != spec["spec_id"]:
                    raise Blocked("case %s belongs to spec %s, not %s" % (case["id"], case["spec_id"], spec["spec_id"]))
                for cid in case["criteria"]:
                    if cid not in a.criteria:
                        raise Blocked("case %s names unknown criterion %s" % (case["id"], cid))
                if case["type"] == "safety" and not (set(case["criteria"]) & a.critical):
                    raise Blocked("safety case %s has no critical criterion" % case["id"])
                a.cases[case["id"]] = case
                a.case_files[case["id"]] = p
    lines = "".join("%s\0%s\n" % (cid, sha256_text(canonical(a.cases[cid]))) for cid in sorted(a.cases))
    a.case_set_sha = sha256_text(lines)
    return a


# --------------------------------------------------------------------------
# process execution (no shell, process group, time limit)
# --------------------------------------------------------------------------
def run_proc(argv, cwd, env, timeout, stdout_path=None):
    """Run argv. Returns (returncode or None, timed_out, stdout_size)."""
    out_f = open(stdout_path, "wb") if stdout_path else subprocess.DEVNULL
    try:
        try:
            p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=out_f,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            return None, False, -1, str(e)
        try:
            p.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            p.wait()
        try:
            os.killpg(p.pid, signal.SIGKILL)   # stragglers in the group
        except OSError:
            pass
    finally:
        if stdout_path:
            out_f.close()
    size = os.path.getsize(stdout_path) if stdout_path else 0
    return (None if timed_out else p.returncode), timed_out, size, ""


def minimal_env(extra=()):
    keep = ["PATH", "LANG", "LC_ALL", "TZ", "TMPDIR"] + list(extra)
    return {k: os.environ[k] for k in keep if k in os.environ}


def grader_env():
    return {k: os.environ[k] for k in ("PATH", "LANG") if k in os.environ}


def grader_path(eval_dir, grader_id, g):
    rel = g["path"]
    if rel.startswith("graders/"):
        rel = rel[len("graders/"):]
    return resolve_inside(os.path.join(eval_dir, "graders"), rel, "grader %s" % grader_id)


def run_grader(assets, grader_id, case, evidence_path, tmp):
    """Run one grader. Returns ("pass"|"fail", grader_sha256). Anything else raises Blocked."""
    g = assets.spec["graders"].get(grader_id)
    if g is None:
        raise Blocked("unknown grader %s" % grader_id)
    path = grader_path(assets.dir, grader_id, g)
    if not os.path.isfile(path):
        raise Blocked("grader file missing: %s" % grader_id)
    interp = g.get("interpreter", "python")
    if interp == "python":
        argv = [sys.executable, "-I", path]
    else:
        if not os.access(path, os.X_OK):
            raise Blocked("grader %s is not executable" % grader_id)
        argv = [path]
    case_file = os.path.join(tmp, "case.json")
    with open(case_file, "w", encoding="utf-8") as f:
        json.dump(case, f)
    ref_dir = os.path.join(assets.dir, "snapshots", assets.spec["reference"]["snapshot_id"])
    argv += [case_file, evidence_path, ref_dir]
    code, timed_out, _, err = run_proc(argv, tmp, grader_env(), GRADER_TIMEOUT)
    if timed_out:
        raise Blocked("grader %s timed out" % grader_id)
    if code is None:
        raise Blocked("grader %s could not start: %s" % (grader_id, err))
    if code == 0:
        return "pass", sha256_file(path)
    if code == 1:
        return "fail", sha256_file(path)
    raise Blocked("grader %s returned exit code %s (grading error)" % (grader_id, code))


def grade_criteria(assets, case, criteria_ids, evidence_path, tmp, hashes):
    results = {}
    for cid in criteria_ids:
        crit = assets.criteria[cid]
        verdict, gsha = run_grader(assets, crit["grader_id"], case, evidence_path, tmp)
        hashes[crit["grader_id"]] = gsha
        results[cid] = verdict
    return results


def policy_coverage_ok(assets, evidence, criteria_ids):
    cov = evidence.get("policy_coverage")
    for cid in criteria_ids:
        crit = assets.criteria[cid]
        if crit["kind"] != "policy":
            continue
        if not isinstance(cov, dict):
            return False
        for obs in crit.get("required_observers", []):
            if cov.get(obs) != "active":
                return False
    return True


# --------------------------------------------------------------------------
# self-test of graders
# --------------------------------------------------------------------------
def load_reference_evidence(assets, case, key, tmp):
    rel = case[key + "_ref"]
    path = resolve_inside(assets.dir, rel, "%s of %s" % (key + "_ref", case["id"]))
    if not os.path.isfile(path):
        raise Blocked("%s_ref of %s does not exist: %s" % (key, case["id"], rel))
    with open(path, "rb") as f:
        data = f.read()
    if sha256_bytes(data) != case[key + "_sha256"]:
        raise Blocked("%s evidence of %s does not match its pinned sha256" % (key, case["id"]))
    try:
        ev = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise Blocked("%s evidence of %s is not valid JSON" % (key, case["id"]))
    errs = validate(ev, assets.schemas["evidence"])
    if errs:
        raise Blocked("%s evidence of %s violates the evidence schema: %s" % (key, case["id"], "; ".join(errs[:3])))
    if ev["termination_reason"] != "completed":
        raise Blocked("%s evidence of %s must have termination_reason completed" % (key, case["id"]))
    copy = os.path.join(tmp, "%s-%s.json" % (case["id"], key))
    with open(copy, "wb") as f:
        f.write(data)
    return ev, copy


def selftest(assets, cases, hashes):
    for case in cases:
        for key, want in (("known_bad", "fail"), ("known_good", "pass")):
            if key + "_ref" not in case:
                continue
            with tempfile.TemporaryDirectory(prefix="pe-selftest-") as tmp:
                ev, copy = load_reference_evidence(assets, case, key, tmp)
                if not policy_coverage_ok(assets, ev, case["criteria"]):
                    raise Blocked("%s evidence of %s lacks active policy coverage" % (key, case["id"]))
                res = grade_criteria(assets, case, case["criteria"], copy, tmp, hashes)
                if want == "fail" and "fail" not in res.values():
                    raise Blocked("self-test failed: grader passed the known_bad evidence of %s" % case["id"])
                if want == "pass" and "fail" in res.values():
                    raise Blocked("self-test failed: grader failed the known_good evidence of %s" % case["id"])


# --------------------------------------------------------------------------
# decisions (pure functions; the two gates never share an interpretation)
# --------------------------------------------------------------------------
def decide_regression(slots):
    """slots: list of {"phase", "outcome": pass|fail|unrunnable, ...}. Returns blocked|fail|flaky|pass."""
    reg = [s for s in slots if s["phase"] in ("initial", "extra")]
    if any(s["outcome"] == "unrunnable" for s in reg):
        return "blocked"
    fails = sum(1 for s in reg if s["outcome"] == "fail")
    if fails >= 2:
        return "fail"
    if fails == 1:
        return "flaky"
    return "pass"


def decide_safety(slots, critical_ids):
    """Any failed critical criterion in any slot is a fail. Returns blocked|fail|pass."""
    if any(s["outcome"] == "unrunnable" for s in slots):
        return "blocked"
    failed = False
    for s in slots:
        if s["class"] == "system":
            failed = True
            continue
        for cid in critical_ids:
            r = s["criteria"].get(cid)
            if r is None:
                return "blocked"
            if r == "fail":
                failed = True
    return "fail" if failed else "pass"


# --------------------------------------------------------------------------
# trials
# --------------------------------------------------------------------------
class Run:
    def __init__(self, assets, adapter_argv, out_dir, run_id):
        self.assets = assets
        self.adapter_argv = adapter_argv
        self.out_dir = out_dir
        self.run_id = run_id
        self.grader_hashes = {}
        self.trials_path = os.path.join(out_dir, "trials.jsonl")
        self.ev_dir = os.path.join(out_dir, "evidence")
        os.makedirs(self.ev_dir, exist_ok=True)
        self.adapter_sha = None
        self.evidence_all_valid = True

    def log_trial(self, rec):
        try:
            with open(self.trials_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(rec, sort_keys=True) + "\n")
                f.flush()
                os.fsync(f.fileno())
        except OSError as e:
            raise Blocked("cannot write trials.jsonl: %s" % e)


def mark(rec, reason, cls, detail=None):
    rec["reason"] = reason
    rec["class"] = cls
    if detail is not None:
        rec["detail"] = detail


def classify(reason):
    if reason in INFRA:
        return "infra"
    if reason in SYSTEM:
        return "system"
    return "normal"


def one_attempt(run, case, criteria_ids, label):
    """Run the adapter once and grade. Returns an attempt record (dict)."""
    assets = run.assets
    spec = assets.spec
    timeout = spec.get("adapter", {}).get("timeout_s", ADAPTER_TIMEOUT_DEFAULT)
    allow = spec.get("adapter", {}).get("env_allow", [])
    rec = {"schema_version": 1, "run_id": run.run_id, "case_id": case["id"], "label": label,
           "started_at": now_iso(), "criteria": {}, "evidence_sha256": None}
    with tempfile.TemporaryDirectory(prefix="pe-trial-") as tmp:
        work = os.path.join(tmp, "work")
        os.makedirs(work)
        case_file = os.path.join(tmp, "adapter-case.json")
        with open(case_file, "w", encoding="utf-8") as f:
            json.dump({"id": case["id"], "input": case["input"]}, f)
        out_path = os.path.join(tmp, "stdout.json")
        env = minimal_env(allow)
        env["PE_CASE_FILE"] = case_file
        env["PE_WORKDIR"] = work
        code, timed_out, size, err = run_proc(run.adapter_argv, work, env, timeout, out_path)
        if timed_out:
            mark(rec, "adapter_timeout", "system")
        elif code is None:
            mark(rec, "adapter_crashed", "infra", err)
        elif code != 0:
            mark(rec, "adapter_crashed", "infra", "exit %s" % code)
        elif size > EVIDENCE_CAP:
            mark(rec, "evidence_invalid", "infra", "stdout larger than %d bytes" % EVIDENCE_CAP)
        else:
            with open(out_path, "rb") as f:
                data = f.read()
            try:
                ev = json.loads(data.decode("utf-8"))
                errs = validate(ev, assets.schemas["evidence"])
            except (ValueError, UnicodeDecodeError):
                ev, errs = None, ["not valid JSON"]
            if errs:
                mark(rec, "evidence_invalid", "infra", "; ".join(errs[:3]))
            else:
                rec["evidence_sha256"] = sha256_bytes(data)
                ev_name = "%s-%s.json" % (case["id"], label)
                with open(os.path.join(run.ev_dir, ev_name), "wb") as f:
                    f.write(data)
                reason = ev["termination_reason"]
                cls = classify(reason)
                mark(rec, reason, cls)
                if cls == "normal":
                    if not policy_coverage_ok(assets, ev, criteria_ids):
                        mark(rec, "policy_coverage_inactive", "infra")
                    else:
                        rec["criteria"] = grade_criteria(assets, case, criteria_ids, out_path, tmp, run.grader_hashes)
    rec["ended_at"] = now_iso()
    return rec


def run_slot(run, case, criteria_ids, phase, index):
    """One trial slot = first attempt plus up to 2 re-runs when the failure is infrastructure."""
    final = None
    for attempt in range(3):
        rec = one_attempt(run, case, criteria_ids, "t%d-a%d" % (index, attempt))
        rec.update(slot=index, attempt=attempt, phase=phase)
        run.log_trial(rec)
        final = rec
        if rec["class"] != "infra":
            break
    if final["reason"] == "evidence_invalid":
        run.evidence_all_valid = False
    if final["class"] == "infra":
        outcome = "unrunnable"
    elif final["class"] == "system":
        outcome = "fail"
    else:
        outcome = "fail" if "fail" in final["criteria"].values() else "pass"
    return {"phase": phase, "outcome": outcome, "class": final["class"], "criteria": final["criteria"],
            "reason": final["reason"]}


# --------------------------------------------------------------------------
# gate
# --------------------------------------------------------------------------
def select_cases(assets, gate):
    reg, saf = [], []
    for cid in sorted(assets.cases):
        c = assets.cases[cid]
        if gate in ("regression", "all") and c["type"] == "regression":
            reg.append(c)
        if gate in ("safety", "all") and (c["type"] == "safety" or (set(c["criteria"]) & assets.critical)):
            saf.append(c)
    return reg, saf


def write_json(path, obj):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, sort_keys=True)
            f.write("\n")
    except OSError as e:
        raise Blocked("cannot write %s: %s" % (path, e))


def load_system_manifest(path):
    data = read_json(path, "system manifest")
    if not isinstance(data, dict):
        raise Blocked("system manifest must be a JSON object")
    return {k: data[k] for k in ("comparison_purpose", "system", "env", "budget") if k in data}


def build_manifest(run, sysm, mode, trusted_ref, assets_sha, trials_per_case, started, root):
    a = run.assets
    env = dict(sysm.get("env", {}))
    if "repo_commit" not in env and root:
        try:
            env["repo_commit"] = git(["rev-parse", "HEAD"], root)
        except Blocked:
            pass
    return {
        "manifest_version": "1", "run_id": run.run_id, "run_started_at": started, "mode": mode,
        "comparison_purpose": sysm.get("comparison_purpose"), "system": sysm.get("system"),
        "env": env or None, "budget": sysm.get("budget"),
        "evaluation": {
            "spec_id": a.spec["spec_id"], "spec_version": a.spec["spec_version"],
            "case_set_sha256": a.case_set_sha, "grader_sha256": dict(sorted(run.grader_hashes.items())),
            "snapshot_id": a.spec["reference"]["snapshot_id"], "decision_sha256": a.decision_sha,
            "decision_fixed_at": a.spec["decision"]["fixed_at"], "assets_sha256": assets_sha,
            "trusted_ref": trusted_ref},
        "execution": {"trials_per_case": trials_per_case},
    }


def final_line(status, detail, run_dir):
    print("STATUS: %s%s" % (status, " (%s)" % detail if detail else ""))
    if run_dir:
        print("EVIDENCE: %s" % run_dir)
    return EXIT[status]


def cmd_gate(args):
    started = now_iso()
    trusted = args.trusted_ref is not None
    mode = "trusted" if trusted else "local"
    mode_label = "trusted" if trusted else "local (unofficial)"
    run_dir = None
    tmp_assets = None
    invariants = dict.fromkeys(("ref_pinned", "assets_verified", "evidence_schema_verified", "selftest_passed",
                                "graded_with_ref_copies", "gate_executed", "artifacts_preserved"), False)
    try:
        try:
            adapter_argv = json.loads(args.adapter_cmd)
            if not (isinstance(adapter_argv, list) and adapter_argv and all(isinstance(x, str) for x in adapter_argv)):
                raise ValueError
        except ValueError:
            raise Blocked("--adapter-cmd must be a non-empty JSON array of strings")
        eval_dir_arg = os.path.abspath(args.eval_dir)
        review = []
        trusted_sha = None
        root = None
        if not os.path.isdir(eval_dir_arg):
            raise Blocked("eval dir not found: %s" % eval_dir_arg)
        if trusted:
            root = repo_root(os.getcwd())
            rel_dir = os.path.relpath(os.path.realpath(eval_dir_arg), os.path.realpath(root)).replace(os.sep, "/")
            if rel_dir.startswith(".."):
                raise Blocked("--eval-dir must be inside the repository for trusted mode")
            try:
                trusted_sha = git(["rev-parse", "--verify", "--quiet", args.trusted_ref + "^{commit}"], root)
            except Blocked:
                raise Blocked("cannot resolve --trusted-ref %s" % args.trusted_ref)
            if not trusted_sha:
                raise Blocked("cannot resolve --trusted-ref %s" % args.trusted_ref)
            ref_pe = git(["show", "%s:%s/pe.py" % (trusted_sha, rel_dir)], root, binary=True)
            with open(os.path.realpath(__file__), "rb") as f:
                if f.read() != ref_pe:
                    raise Blocked("the running pe.py differs from %s/pe.py at the trusted ref" % rel_dir)
            invariants["ref_pinned"] = True
            mode_label = "trusted (ref=%s)" % trusted_sha
            tmp_assets = tempfile.mkdtemp(prefix="pe-ref-")
            extract_ref_tree(root, trusted_sha, rel_dir, tmp_assets)
            eval_dir = os.path.join(tmp_assets, *rel_dir.split("/"))
            ref_digest, ref_entries = assets_digest(eval_dir)
            head_digest, head_entries = assets_digest(eval_dir_arg)
            assets_sha = ref_digest
            if head_digest != ref_digest:
                changed = sorted(k for k in set(ref_entries) | set(head_entries) if ref_entries.get(k) != head_entries.get(k))
                review.append("evaluation assets differ from %s: %s" % (trusted_sha[:12], ", ".join(changed[:8])))
            else:
                invariants["assets_verified"] = True
            invariants["graded_with_ref_copies"] = True
        else:
            eval_dir = eval_dir_arg
            assets_sha, _ = assets_digest(eval_dir)
            try:
                root = repo_root(os.getcwd())
            except Blocked:
                root = None
        assets = load_assets(eval_dir)
        sysm = load_system_manifest(args.system_manifest)
        decision = assets.spec["decision"]
        if parse_when(decision["fixed_at"]) > parse_when(started):
            raise Blocked("decision.fixed_at (%s) is later than this run" % decision["fixed_at"])
        reg_cases, saf_cases = select_cases(assets, args.gate)
        out_root = os.path.abspath(args.out)
        run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-%d" % os.getpid()
        run_dir = os.path.join(out_root, run_id)
        try:
            os.makedirs(run_dir)
        except OSError as e:
            run_dir = None
            raise Blocked("cannot create run directory: %s" % e)
        run = Run(assets, adapter_argv, run_dir, run_id)
        run.adapter_sha = sha256_text(canonical(adapter_argv))
        selected = {}
        for c in reg_cases + saf_cases:
            selected[c["id"]] = c
        if not selected:
            return finish(run, "NOT RUN", "no case selected for gate %s" % args.gate, mode, mode_label, trusted_sha,
                          assets_sha, invariants, review, {}, {}, {}, sysm, started, root)
        selftest(assets, [selected[k] for k in sorted(selected)], run.grader_hashes)
        invariants["selftest_passed"] = True

        reg_ids = {c["id"] for c in reg_cases}
        saf_ids = {c["id"] for c in saf_cases}
        slots = {}
        trials_per_case = {}
        for cid in sorted(selected):
            case = selected[cid]
            if cid in reg_ids:
                crit = list(case["criteria"])
            else:
                crit = [x for x in case["criteria"] if x in assets.critical]
            lst = []
            slots[cid] = lst
            if cid in reg_ids:
                for i in range(3):
                    lst.append(run_slot(run, case, crit, "initial", len(lst) + 1))
                bad = sum(1 for s in lst if s["outcome"] != "pass")
                unrunnable = any(s["outcome"] == "unrunnable" for s in lst)
                if bad == 1 and not unrunnable:
                    for i in range(3):
                        lst.append(run_slot(run, case, crit, "extra", len(lst) + 1))
                elif unrunnable:
                    pass
            if cid in saf_ids:
                want = decision["safety_trials"]
                while len(lst) < want and not any(s["outcome"] == "unrunnable" for s in lst):
                    lst.append(run_slot(run, case, crit, "safety", len(lst) + 1))
            trials_per_case[cid] = len(lst)

        reg_dec = {cid: decide_regression(slots[cid]) for cid in sorted(reg_ids)}
        saf_dec = {cid: decide_safety(slots[cid], [x for x in selected[cid]["criteria"] if x in assets.critical])
                   for cid in sorted(saf_ids)}
        invariants["gate_executed"] = True
        invariants["evidence_schema_verified"] = run.evidence_all_valid
        return finish(run, None, None, mode, mode_label, trusted_sha, assets_sha, invariants, review,
                      reg_dec, saf_dec, trials_per_case, sysm, started, root, selected=selected, saf_ids=saf_ids,
                      assets=assets)
    except Blocked as e:
        if run_dir and os.path.isdir(run_dir):
            try:
                write_json(os.path.join(run_dir, "result.json"), {"status": "BLOCKED", "detail": str(e), "mode": mode,
                                                                    "invariants": invariants, "tool_version": TOOL_VERSION})
            except Blocked:
                pass
        print("MODE: %s" % mode_label)
        return final_line("BLOCKED", str(e), run_dir)
    finally:
        if tmp_assets:
            shutil.rmtree(tmp_assets, ignore_errors=True)


def finish(run, forced_status, forced_detail, mode, mode_label, trusted_sha, assets_sha, invariants, review,
           reg_dec, saf_dec, trials_per_case, sysm, started, root, selected=None, saf_ids=None, assets=None):
    lines = []
    status, detail = forced_status, forced_detail
    if status is None:
        blocked = [c for c, d in list(reg_dec.items()) + list(saf_dec.items()) if d == "blocked"]
        failed = [c for c, d in list(reg_dec.items()) + list(saf_dec.items()) if d == "fail"]
        flaky = [c for c, d in reg_dec.items() if d == "flaky"]
        for c, d in sorted(reg_dec.items()):
            lines.append("[regression] %-24s %s (trials=%d)" % (c, d, trials_per_case.get(c, 0)))
        for c, d in sorted(saf_dec.items()):
            lines.append("[safety    ] %-24s %s (trials=%d)" % (c, d, trials_per_case.get(c, 0)))
        if saf_dec:
            fams = {selected[c]["risk_family"] for c in saf_dec}
            lines.append("safety: cases=%d families=%d failures=%d" % (len(saf_dec), len(fams), len([c for c in saf_dec if saf_dec[c] == "fail"])))
            if not [c for c in saf_dec if saf_dec[c] != "pass"]:
                lines.append("safety upper bound over %d families: %.1f%% (assumes families fail independently)"
                             % (len(fams), 100 * family_bound(len(fams))))
                if len(fams) < rule_of_three_n(0.05):
                    lines.append("SAFETY_CLAIM: not demonstrated (%d risk families, %d needed for a 5%% bound)"
                                 % (len(fams), rule_of_three_n(0.05)))
        if flaky:
            lines.append("flaky suspects (passed, one failure in six): %s" % ", ".join(flaky))
        if blocked:
            status, detail = "BLOCKED", "cannot judge: %s" % ", ".join(blocked[:5])
        elif failed:
            status, detail = "FAIL", "failed: %s" % ", ".join(failed[:5])
        elif review:
            status, detail = "NEEDS_REVIEW", "; ".join(review)
        else:
            status, detail = "PASS", "all selected cases passed"
    if status == "PASS" and mode == "trusted":
        missing = [k for k, v in invariants.items() if not v and k != "artifacts_preserved"]
        if missing:
            status, detail = "BLOCKED", "trusted PASS refused; unverified: %s" % ", ".join(missing)
    result = {"status": status, "detail": detail, "mode": mode, "trusted_ref": trusted_sha,
              "tool_version": TOOL_VERSION, "invariants": invariants, "review": review,
              "regression": reg_dec, "safety": saf_dec, "trials_per_case": trials_per_case,
              "started_at": started, "ended_at": now_iso()}
    try:
        if assets is not None:
            manifest = build_manifest(run, sysm, mode, trusted_sha, assets_sha, trials_per_case, started, root)
            merrs = validate(manifest, assets.schemas["manifest"])
            if merrs:
                raise Blocked("manifest invalid: " + "; ".join(merrs[:4]))
            write_json(os.path.join(run.out_dir, "manifest.json"), manifest)
        invariants["artifacts_preserved"] = True
        result["invariants"] = invariants
        write_json(os.path.join(run.out_dir, "result.json"), result)
    except Blocked as e:
        invariants["artifacts_preserved"] = False
        if status in ("PASS", "NEEDS_REVIEW") or forced_status == "NOT RUN":
            status, detail = "BLOCKED", str(e)
        try:
            result.update(status=status, detail=detail, invariants=invariants)
            write_json(os.path.join(run.out_dir, "result.json"), result)
        except Blocked:
            pass
    print("MODE: %s" % mode_label)
    for ln in lines:
        print(ln)
    return final_line(status, detail, run.out_dir)


# --------------------------------------------------------------------------
# validate
# --------------------------------------------------------------------------
def cmd_validate(args):
    try:
        eval_dir = os.path.abspath(args.eval_dir)
        assets = load_assets(eval_dir)
        hashes = {}
        # every referenced evidence file must exist and match its pin
        for cid in sorted(assets.cases):
            case = assets.cases[cid]
            for key in ("known_bad", "known_good"):
                if key + "_ref" in case:
                    with tempfile.TemporaryDirectory(prefix="pe-validate-") as tmp:
                        load_reference_evidence(assets, case, key, tmp)
        for gid, g in assets.spec["graders"].items():
            p = grader_path(eval_dir, gid, g)
            if not os.path.isfile(p):
                raise Blocked("grader file missing: %s" % gid)
            hashes[gid] = sha256_file(p)
        print("validate: spec ok, %d criteria, %d cases, %d graders" % (len(assets.criteria), len(assets.cases), len(hashes)))
        print("STATUS: PASS (valid)")
        return 0
    except Blocked as e:
        print("STATUS: BLOCKED (%s)" % e)
        return EXIT["BLOCKED"]


# --------------------------------------------------------------------------
# compare
# --------------------------------------------------------------------------
def flatten(obj, prefix=""):
    out = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.update(flatten(v, "%s%s." % (prefix, k)))
    else:
        out[prefix.rstrip(".")] = obj
    return out


def cmd_compare(args):
    print("comparability check only; this is not a performance or non-inferiority result")
    try:
        schema_dir = os.path.join(os.path.abspath(args.eval_dir), "schemas")
        schema = read_json(os.path.join(schema_dir, "manifest.schema.json"), "manifest schema")
        check_schema_keywords(schema, "manifest")
        ms = []
        for p in (args.a, args.b):
            m = read_json(p, "manifest")
            errs = validate(m, schema)
            if errs:
                raise Blocked("manifest %s is incomplete or invalid: %s" % (p, "; ".join(errs[:4])))
            if m["comparison_purpose"] != args.purpose:
                raise Blocked("manifest %s declares comparison_purpose %s, not %s" % (p, m["comparison_purpose"], args.purpose))
            ms.append(m)
        a, b = ms
        if a["mode"] != b["mode"]:
            raise Blocked("manifests were produced in different modes (%s vs %s)" % (a["mode"], b["mode"]))
        fa, fb = flatten(a["evaluation"]), flatten(b["evaluation"])
        for k in ("spec_id", "spec_version", "case_set_sha256", "snapshot_id", "decision_sha256", "assets_sha256"):
            if fa[k] != fb[k]:
                raise Blocked("evaluation field differs: %s" % k)
        ga = {k: v for k, v in fa.items() if k.startswith("grader_sha256.")}
        gb = {k: v for k, v in fb.items() if k.startswith("grader_sha256.")}
        if ga != gb:
            raise Blocked("evaluation field differs: grader_sha256")
        fixed = parse_when(a["evaluation"]["decision_fixed_at"])
        for m in (a, b):
            if fixed > parse_when(m["run_started_at"]):
                raise Blocked("decision was fixed (%s) after a run started (%s); decision changed after the fact"
                              % (a["evaluation"]["decision_fixed_at"], m["run_started_at"]))
        diffs = {}
        for section in ("system", "env", "budget"):
            fa_s, fb_s = flatten(a[section], section + "."), flatten(b[section], section + ".")
            for k in sorted(set(fa_s) | set(fb_s)):
                if fa_s.get(k) != fb_s.get(k):
                    diffs[k] = (fa_s.get(k), fb_s.get(k))
        if args.purpose == "component":
            if len(diffs) != 1:
                raise Blocked("component comparison needs exactly one differing field, found %d: %s" % (len(diffs), ", ".join(sorted(diffs)) or "none"))
        elif args.purpose == "controlled":
            fixed_keys = [k for k in diffs if k == "system.tools" or k in ("env.network_scope", "env.data_scope") or k.startswith("budget.")]
            if fixed_keys:
                raise Blocked("controlled comparison needs equal tools, network, data and budget; differing: %s" % ", ".join(sorted(fixed_keys)))
        for k in sorted(diffs):
            print("differs: %s: %r -> %r" % (k, diffs[k][0], diffs[k][1]))
        print("STATUS: COMPARABLE (purpose=%s, mode=%s)" % (args.purpose, a["mode"]))
        return 0
    except Blocked as e:
        print("STATUS: BLOCKED (%s)" % e)
        return EXIT["BLOCKED"]


# --------------------------------------------------------------------------
def build_parser():
    p = argparse.ArgumentParser(prog="pe.py", description="portable-eval gate tool (experimental)")
    sub = p.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate")
    v.add_argument("--eval-dir", default=".eval")
    g = sub.add_parser("gate")
    g.add_argument("gate", choices=["regression", "safety", "all"])
    g.add_argument("--eval-dir", default=".eval")
    g.add_argument("--adapter-cmd", required=True, help='JSON array, e.g. \'["python3","run.py"]\'')
    g.add_argument("--system-manifest", default=None)
    g.add_argument("--trusted-ref", default=None)
    g.add_argument("--out", default=None)
    c = sub.add_parser("compare")
    c.add_argument("a")
    c.add_argument("b")
    c.add_argument("--purpose", required=True, choices=["component", "controlled", "system"])
    c.add_argument("--eval-dir", default=".eval")
    pl = sub.add_parser("plan")
    pl.add_argument("what", choices=["gate-false-block", "regression-block", "rule-of-three", "family-bound",
                                     "ni-n", "mde", "review-prob", "candidate-prob"])
    pl.add_argument("--reliability", type=float, default=0.99)
    pl.add_argument("--cases", type=int, default=100)
    pl.add_argument("--success", type=float, default=0.5)
    pl.add_argument("--bound", type=float, default=0.05)
    pl.add_argument("--families", type=int, default=10)
    pl.add_argument("--psi", type=float, default=0.2)
    pl.add_argument("--margin", type=float, default=0.05)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.cmd == "gate":
        if args.system_manifest is None:
            args.system_manifest = os.path.join(args.eval_dir, "system-manifest.json")
        if args.out is None:
            args.out = os.path.join(args.eval_dir, "runs")
        return cmd_gate(args)
    if args.cmd == "validate":
        return cmd_validate(args)
    if args.cmd == "compare":
        return cmd_compare(args)
    return cmd_plan(args)


if __name__ == "__main__":
    sys.exit(main())
