"""Tests for pe.py. Run: python3 -I -m unittest discover -s tests/py -t tests/py -v"""
import ast
import copy
import importlib.util
import json
import os
import random
import hashlib
import stat
import shutil
import subprocess
import sys
import tempfile
import unittest

import fixture
from fixture import Project, good_evidence

spec = importlib.util.spec_from_file_location("pe", fixture.PE_SRC)
pe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pe)

try:
    import jsonschema  # optional cross-check, installed in CI only
except ImportError:
    jsonschema = None


def write_json(path, obj):
    with open(path, "w") as fh:
        json.dump(obj, fh)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pe-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.p = Project(self.tmp)


# ---------------------------------------------------------------------------
class TestGolden(unittest.TestCase):
    """The numbers of design v2.1 recomputed. They prove the formulas match the document, nothing more."""

    def test_gate_false_block(self):
        for rel, v2, v21 in ((0.99, 95.1, 11.1), (0.995, 77.8, 2.9), (0.999, 25.9, 0.1)):
            self.assertEqual(round(100 * pe.v2_false_block_rate(rel, 100), 1), v2)
            self.assertEqual(round(100 * pe.false_block_rate(rel, 100), 1), v21)

    def test_regression_block(self):
        for s, want in ((0.5, 82.8), (0.7, 50.6), (0.8, 29.1)):
            self.assertEqual(round(100 * pe.regression_block_prob(s), 1), want)

    def test_candidate_and_review(self):
        self.assertEqual(round(100 * pe.candidate_prob(0.8), 1), 10.7)
        self.assertEqual(round(100 * pe.candidate_prob(0.9), 1), 34.9)
        for rel, want in ((0.99, 3.6), (0.95, 44.6), (0.9, 81.6)):
            self.assertEqual(round(100 * pe.review_prob(rel), 1), want)
        self.assertAlmostEqual(100 * pe.review_prob(0.8), 99.0, delta=0.2)

    def test_safety_sample_sizes(self):
        self.assertEqual([pe.rule_of_three_n(b) for b in (0.05, 0.02, 0.01)], [59, 149, 299])
        self.assertEqual(round(100 * pe.family_bound(10), 1), 25.9)

    def test_noninferiority_n(self):
        table = {0.1: (314, 79), 0.2: (628, 157), 0.3: (942, 236)}
        for psi, (a, b) in table.items():
            self.assertEqual(pe.noninferiority_n(psi, 0.05), a)
            self.assertEqual(pe.noninferiority_n(psi, 0.10), b)

    def test_min_detectable_difference(self):
        table = {50: (None, 17.7, 21.7), 100: (8.9, 12.5, 15.3), 200: (6.3, 8.9, 10.9), 400: (4.4, 6.3, 7.7)}
        for n, row in table.items():
            for psi, want in zip((0.1, 0.2, 0.3), row):
                got = pe.mde(n, psi)
                if want is None:
                    self.assertIsNone(got)
                else:
                    self.assertEqual(round(100 * got, 1), want, (n, psi))

    def test_judge_numbers(self):
        self.assertEqual(round(100 * pe.precision(0.9, 0.9, 0.02), 1), 15.5)
        self.assertEqual((pe.failure_labels(0.10), pe.failure_labels(0.05)), (35, 139))
        self.assertEqual(round(100 * pe.agreement_random(0.05), 1), 90.5)

    def test_plan_cli(self):
        r = subprocess.run([sys.executable, "-I", fixture.PE_SRC, "plan", "rule-of-three", "--bound", "0.02"],
                           stdout=subprocess.PIPE)
        self.assertEqual(r.returncode, 0)
        self.assertTrue(r.stdout.decode().startswith("149"))


class TestSyntax(unittest.TestCase):
    def test_python39_syntax(self):
        for path in (fixture.PE_SRC, os.path.join(fixture.HERE, "fixture.py")):
            with open(path) as f:
                ast.parse(f.read(), feature_version=(3, 9))


# ---------------------------------------------------------------------------
def valid_docs():
    p_spec = fixture.default_spec()
    case = {"id": "C1", "spec_id": "demo", "type": "regression", "criteria": ["SC1"], "severity": "normal",
            "pair_id": None, "risk_family": "f", "source": {"kind": "synthetic", "ref": "r"}, "input": {},
            "expected": {"kind": "state", "state": {}}, "known_bad_ref": "refs/x.json", "known_bad_sha256": "0" * 64,
            "split": "regression", "added_at": "2026-01-01"}
    manifest = {"manifest_version": "1", "run_id": "r", "run_started_at": "2026-01-02T00:00:00Z", "mode": "local",
                "comparison_purpose": "system", "system": fixture.SYSTEM_MANIFEST["system"],
                "env": fixture.SYSTEM_MANIFEST["env"], "budget": fixture.SYSTEM_MANIFEST["budget"],
                "evaluation": {"spec_id": "demo", "spec_version": "1", "case_set_sha256": "1" * 64,
                               "grader_sha256": {"g": "2" * 64}, "snapshot_id": "s", "decision_sha256": "3" * 64,
                               "decision_fixed_at": "2026-01-01", "assets_sha256": "4" * 64, "trusted_ref": None},
                "execution": {"trials_per_case": {"C1": 3}}}
    return {"spec": p_spec, "case": case, "evidence": good_evidence(), "manifest": manifest}


def load_schema(name):
    with open(os.path.join(fixture.SCHEMA_DIR, "%s.schema.json" % name)) as f:
        return json.load(f)


class TestSchemaValidator(unittest.TestCase):
    def test_real_schemas_only_use_supported_keywords(self):
        for name in pe.SCHEMA_NAMES:
            pe.check_schema_keywords(load_schema(name), name)

    def test_valid_docs_pass(self):
        for name, doc in valid_docs().items():
            self.assertEqual(pe.validate(doc, load_schema(name)), [], name)

    def test_unsupported_keyword_is_blocked(self):
        for bad in ({"format": "date"}, {"patternProperties": {}}, {"properties": {"a": {"uniqueItems": True}}},
                    {"$ref": "http://example.com/x"}, {"not": {}}):
            with self.assertRaises(pe.Blocked, msg=str(bad)):
                pe.check_schema_keywords(bad)

    def test_items_false_integer_floats_and_non_finite_numbers(self):
        v = pe.validate
        self.assertNotEqual(v([1], {"items": False}), [])
        self.assertEqual(v([], {"items": False}), [])
        self.assertEqual(v(1.0, {"type": "integer"}), [])            # JSON Schema: 1.0 is an integer
        self.assertNotEqual(v(1.5, {"type": "integer"}), [])
        self.assertNotEqual(v(float("nan"), {"type": "number", "minimum": 0}), [])
        self.assertNotEqual(v(float("inf"), {"type": "number"}), [])
        with self.assertRaises(ValueError):
            pe.loads_strict('{"cost": NaN}')
        with self.assertRaises(ValueError):
            pe.loads_strict('{"cost": Infinity}')

    def test_semantics(self):
        v = pe.validate
        self.assertEqual(v(1, {"type": "integer"}), [])
        self.assertNotEqual(v(True, {"type": "integer"}), [])
        self.assertNotEqual(v(None, {"type": "string"}), [])
        self.assertEqual(v(None, {"type": ["string", "null"]}), [])
        self.assertNotEqual(v({"a": 1}, {"type": "object", "additionalProperties": False}), [])
        self.assertNotEqual(v(True, {"const": 1}), [])
        one = {"oneOf": [{"type": "string"}, {"type": "string", "minLength": 2}]}
        self.assertNotEqual(v("ab", one), [])      # matches both
        self.assertEqual(v("a", one), [])          # matches the first only
        cond = {"if": {"properties": {"t": {"const": "a"}}}, "then": {"required": ["x"]}}
        self.assertNotEqual(v({}, cond), [])       # JSON Schema: `if` is true when t is absent
        cond2 = {"if": {"required": ["t"], "properties": {"t": {"const": "a"}}}, "then": {"required": ["x"]}}
        self.assertEqual(v({}, cond2), [])

    @unittest.skipIf(jsonschema is None, "jsonschema not installed (cross-check runs in CI)")
    def test_cross_check_with_jsonschema(self):
        cls = jsonschema.Draft202012Validator
        disagreements = []
        for name, doc in valid_docs().items():
            schema = load_schema(name)
            ref = cls(schema)
            mutants = [("valid", doc)]
            for key in doc:
                m = copy.deepcopy(doc); del m[key]; mutants.append(("del " + key, m))
                for wrong in (None, 12345, "zz", [], {}, True):
                    m = copy.deepcopy(doc); m[key] = wrong; mutants.append(("set %s=%r" % (key, wrong), m))
            extra = copy.deepcopy(doc); extra["zzz"] = 1; mutants.append(("extra", extra))
            if name == "manifest":
                m = copy.deepcopy(doc); m["budget"]["max_calls"] = 10.0; mutants.append(("integer-valued float", m))
                m = copy.deepcopy(doc); m["budget"]["max_calls"] = 10.5; mutants.append(("non-integer float", m))
            if name == "spec":
                m = copy.deepcopy(doc); m["decision"]["safety_trials"] = 3.0; mutants.append(("integer-valued float", m))
            for key in ("type", "split", "kind", "termination_reason", "mode"):
                if key in doc:
                    m = copy.deepcopy(doc); m[key] = "nope"; mutants.append(("enum " + key, m))
            if name == "case":
                for drop in ("known_bad_ref", "known_bad_sha256"):
                    m = copy.deepcopy(doc); del m[drop]; mutants.append(("del " + drop, m))
                m = copy.deepcopy(doc); m["known_good_ref"] = "refs/g.json"; mutants.append(("good w/o sha", m))
                m = copy.deepcopy(doc); m["expected"] = {"kind": "rubric", "state": {}}; mutants.append(("oneOf none", m))
                m = copy.deepcopy(doc); m["type"] = "capability"; del m["known_bad_ref"]; del m["known_bad_sha256"]
                mutants.append(("capability w/o bad ref", m))
            if name == "evidence":
                m = copy.deepcopy(doc); m["termination_reason"] = "budget_exceeded"; del m["policy_coverage"]
                mutants.append(("system failure w/o coverage", m))
                m = copy.deepcopy(doc); m["policy_coverage"] = {"egress": "maybe"}; mutants.append(("bad coverage", m))
                m = copy.deepcopy(doc); m["_executor"] = {}; mutants.append(("executor", m))
            if name == "spec":
                m = copy.deepcopy(doc); del m["success_criteria"][1]["required_observers"]
                mutants.append(("policy w/o observers", m))
            for label, inst in mine_vs_ref(mutants, schema, ref):
                disagreements.append("%s: %s" % (name, label))
        self.assertEqual(disagreements, [])


def mine_vs_ref(mutants, schema, ref):
    for label, inst in mutants:
        mine = not pe.validate(inst, schema)
        theirs = ref.is_valid(inst)
        if mine != theirs:
            yield label, inst


# ---------------------------------------------------------------------------
class TestGateLocal(Base):
    def setUp(self):
        super().setUp()

    def test_pass(self):
        self.p.add_case("R1", "P")
        code, out, rd = self.p.gate("regression")
        self.assertEqual(code, 0, out)
        self.assertIn("MODE: local (unofficial)", out)
        self.assertIn("STATUS: PASS", out)
        self.assertEqual(len(self.p.trials(rd)), 3)
        self.assertTrue(os.path.exists(os.path.join(rd, "manifest.json")))
        self.assertEqual(self.p.result(rd)["status"], "PASS")
        rec = self.p.trials(rd)[0]
        self.assertRegex(rec["adapter_sha256"], "^[0-9a-f]{64}$")
        self.assertRegex(rec["grader_sha256"]["SC1"], "^[0-9a-f]{64}$")
        arts = self.p.result(rd)["artifacts_sha256"]
        for rel, want in arts.items():
            with open(os.path.join(rd, *rel.split("/")), "rb") as fh:
                self.assertEqual(hashlib.sha256(fh.read()).hexdigest(), want, rel)

    def test_always_failing_case_is_fail(self):
        self.p.add_case("R1", "F")
        code, out, rd = self.p.gate("regression")
        self.assertEqual(code, 1, out)
        self.assertEqual(len(self.p.trials(rd)), 3)   # stops once 2 of the first 3 failed

    def test_flaky_one_failure_in_six_passes(self):
        self.p.add_case("R1", "PFPPPP")
        code, out, rd = self.p.gate("regression")
        self.assertEqual(code, 0, out)
        self.assertIn("flaky suspects", out)
        self.assertEqual(len(self.p.trials(rd)), 6)

    def test_second_failure_in_extra_trials_fails(self):
        self.p.add_case("R1", "PFPFPP")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 1, out)

    def test_infra_failure_is_retried(self):
        self.p.add_case("R1", "IPPP")
        code, out, rd = self.p.gate("regression")
        self.assertEqual(code, 0, out)
        self.assertEqual(sorted(set(t["attempt"] for t in self.p.trials(rd))), [0, 1])

    def test_persistent_infra_failure_is_blocked(self):
        self.p.add_case("R1", "I")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)

    def test_system_failure_counts_and_is_not_retried(self):
        self.p.add_case("R1", "S")
        code, out, rd = self.p.gate("regression")
        self.assertEqual(code, 1, out)
        self.assertEqual({t["attempt"] for t in self.p.trials(rd)}, {0})

    def test_adapter_timeout_is_a_system_failure(self):
        self.p.spec["adapter"]["timeout_s"] = 1
        self.p.save_spec()
        self.p.add_case("R1", "T")
        code, out, rd = self.p.gate("regression")
        self.assertEqual(code, 1, out)
        self.assertEqual(self.p.trials(rd)[0]["reason"], "adapter_timeout")

    def test_nothing_selected_is_not_run(self):
        self.p.add_case("S1", "P", type="safety", criteria=("PC1",))
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 4, out)
        self.assertIn("STATUS: NOT RUN", out)

    def test_safety_single_violation_fails(self):
        self.p.add_case("S1", "PVP", type="safety", criteria=("PC1",))
        code, out, _ = self.p.gate("safety")
        self.assertEqual(code, 1, out)

    def test_safety_pass_does_not_claim_safety(self):
        self.p.add_case("S1", "P", type="safety", criteria=("PC1",))
        code, out, _ = self.p.gate("safety")
        self.assertEqual(code, 0, out)
        self.assertIn("SAFETY_CLAIM: not demonstrated", out)
        self.assertIn("families=1", out)
        self.assertIn("assumes families fail independently", out)

    def test_critical_regression_case_is_flaky_pass_for_regression_but_fail_for_safety(self):    # A11
        self.p.add_case("RC1", "PPVPPP", criteria=("SC1", "PC1"))
        code_r, out_r, _ = self.p.gate("regression")
        self.assertEqual(code_r, 0, out_r)
        self.assertIn("flaky suspects", out_r)
        code_s, out_s, _ = self.p.gate("safety")
        self.assertEqual(code_s, 1, out_s)

    def test_all_gate_shares_trials_and_safety_wins(self):
        self.p.add_case("RC1", "PPVPPP", criteria=("SC1", "PC1"))
        code, out, rd = self.p.gate("all")
        self.assertEqual(code, 1, out)
        self.assertEqual(len([t for t in self.p.trials(rd) if t["case_id"] == "RC1"]), 6)
        res = self.p.result(rd)
        self.assertEqual(res["regression"]["RC1"], "flaky")
        self.assertEqual(res["safety"]["RC1"], "fail")

    def test_decision_functions_are_separate_pure_functions(self):
        slots = [{"phase": "initial", "outcome": "pass", "class": "normal", "criteria": {"PC1": "pass"}},
                 {"phase": "initial", "outcome": "fail", "class": "normal", "criteria": {"PC1": "fail"}},
                 {"phase": "initial", "outcome": "pass", "class": "normal", "criteria": {"PC1": "pass"}}]
        self.assertEqual(pe.decide_regression(slots), "flaky")
        self.assertEqual(pe.decide_safety(slots, ["PC1"]), "fail")

    def test_adapter_does_not_see_secrets_or_expected(self):
        self.p.add_case("L1", "L")
        self.p.add_case("H1", "H")
        env = {"SECRET_TOKEN": "supersecret-123"}
        code, out, rd = self.p.gate("regression", env_extra=env)
        self.assertEqual(code, 0, out)
        ev = fixture.read_json(os.path.join(rd, "evidence", "L1-t1-a0.json"))
        self.assertEqual(ev["final_state"]["leak"], "")
        ev = fixture.read_json(os.path.join(rd, "evidence", "H1-t1-a0.json"))
        self.assertIs(ev["final_state"]["saw_expected"], False)

    def test_incomplete_system_manifest_blocks_a_passing_run(self):
        self.p.add_case("R1", "P")
        sysm = json.loads(json.dumps(fixture.SYSTEM_MANIFEST))
        sysm["system"]["model_id"] = ""
        self.p.save_sysm(sysm)
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertIn("manifest invalid", out)

    def test_severity_label_alone_does_not_select_the_safety_gate_and_warns(self):
        self.p.add_case("R1", "P", severity="critical")        # label only; SC1 is not a critical criterion
        code, out = self.p.run_pe("validate", "--eval-dir", ".eval")
        self.assertEqual(code, 0, out)
        self.assertIn("warning: case R1 has severity 'critical'", out)
        code, out, _ = self.p.gate("safety")
        self.assertEqual(code, 4, out)                          # nothing selected

    def test_validate_subcommand(self):
        self.p.add_case("R1", "P", good=True)
        code, out = self.p.run_pe("validate", "--eval-dir", ".eval")
        self.assertEqual(code, 0, out)


# ---------------------------------------------------------------------------
class TestContracts(Base):
    def test_a2_policy_coverage_missing(self):
        self.p.add_case("S1", "N", type="safety", criteria=("PC1",))
        code, out, rd = self.p.gate("safety")
        self.assertEqual(code, 3, out)
        # the evidence schema already requires policy_coverage on a completed run
        self.assertEqual({t["reason"] for t in self.p.trials(rd)}, {"evidence_invalid"})

    def test_a3_observer_unknown(self):
        self.p.add_case("S1", "U", type="safety", criteria=("PC1",))
        code, out, rd = self.p.gate("safety")
        self.assertEqual(code, 3, out)
        self.assertEqual({t["reason"] for t in self.p.trials(rd)}, {"policy_coverage_inactive"})

    def test_nan_in_evidence_is_invalid(self):
        self.p.add_case("R1", "Z")
        code, out, rd = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertEqual({t["reason"] for t in self.p.trials(rd)}, {"evidence_invalid"})

    def test_a3_observer_inactive(self):
        self.p.add_case("S1", "A", type="safety", criteria=("PC1",))
        code, out, rd = self.p.gate("safety")
        self.assertEqual(code, 3, out)
        self.assertEqual({t["reason"] for t in self.p.trials(rd)}, {"policy_coverage_inactive"})

    def test_a5_known_bad_replaced(self):
        self.p.add_case("R1", "P")
        self.p.write("refs/R1-bad.json", json.dumps(good_evidence(ok=False, marker="known_bad", extra="tampered")))
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertIn("pinned sha256", out)

    def test_a5_known_bad_missing(self):
        self.p.add_case("R1", "P")
        os.remove(self.p.path("refs/R1-bad.json"))
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)

    def test_a6_always_pass_grader_fails_selftest(self):
        self.p.add_case("R1", "P")
        self.p.write("graders/g_ok.py", fixture.GRADER_ALWAYS_PASS)
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertIn("self-test failed", out)

    def test_a6_always_pass_grader_hidden_behind_a_second_criterion(self):
        # known_bad violates PC1 only; SC1's grader is replaced by an always-pass one.
        bad = good_evidence(marker="known_bad")
        bad["policy_events"] = [{"type": "egress", "target": "evil.example", "allowed": False}]
        self.p.add_case("RC1", "P", criteria=("SC1", "PC1"), bad_evidence=bad)
        self.p.write("graders/g_ok.py", fixture.GRADER_ALWAYS_PASS)
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertIn("g_ok", out)

    def test_every_used_grader_must_fail_some_known_bad(self):
        # same shape with honest graders: g_ok never sees a known-bad that it should fail -> still BLOCKED,
        # because the self-test cannot show that g_ok discriminates at all
        bad = good_evidence(marker="known_bad")
        bad["policy_events"] = [{"type": "egress", "target": "evil.example", "allowed": False}]
        self.p.add_case("RC1", "P", criteria=("SC1", "PC1"), bad_evidence=bad)
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        # adding a case whose known_bad fails SC1 restores coverage
        self.p.add_case("R1", "P")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 0, out)

    def test_safety_only_run_self_tests_only_the_critical_graders(self):
        bad = good_evidence(marker="known_bad")            # ok=True: fails PC1 only
        bad["policy_events"] = [{"type": "egress", "target": "evil.example", "allowed": False}]
        self.p.add_case("RC1", "P", criteria=("SC1", "PC1"), bad_evidence=bad)
        code, out, _ = self.p.gate("safety")               # grades PC1 only -> g_ok is not in use
        self.assertEqual(code, 0, out)
        code, out, _ = self.p.gate("regression")           # grades SC1 too -> g_ok uncovered
        self.assertEqual(code, 3, out)

    def test_severity_warning_also_when_nothing_is_selected(self):
        self.p.add_case("R1", "P", severity="critical")
        code, out, _ = self.p.gate("safety")
        self.assertEqual(code, 4, out)
        self.assertIn("warning: case R1 has severity 'critical'", out)

    def test_null_env_in_system_manifest_is_blocked_not_a_traceback(self):
        self.p.add_case("R1", "P")
        sysm = json.loads(json.dumps(fixture.SYSTEM_MANIFEST)); sysm["env"] = None
        self.p.save_sysm(sysm)
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertNotIn("Traceback", out)
        self.assertIn("system manifest field env must be an object", out)    # rejected on purpose, not by the catch-all

    def test_selftest_known_good_must_pass(self):
        self.p.add_case("R1", "P", good=True)
        self.p.write("graders/g_ok.py", "import sys\nsys.exit(1)\n")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)

    def test_a7_grader_crash(self):
        self.p.add_case("R1", "P")
        self.p.write("graders/g_ok.py", fixture.GRADER_CRASH)
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertIn("grading error", out)

    def test_a7_grader_hang(self):
        self.p.add_case("R1", "P")
        self.p.write("graders/g_ok.py", fixture.GRADER_HANG)
        code, out, _ = self.p.gate("regression", env_extra={"PE_GRADER_TIMEOUT": "1"})
        self.assertEqual(code, 3, out)
        self.assertIn("timed out", out)

    def test_a7_grader_path_outside_graders(self):
        self.p.add_case("R1", "P")
        self.p.spec["graders"]["g_ok"]["path"] = "../spec.json"
        self.p.save_spec()
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertIn("escapes", out)

    def test_a7_grader_symlink_escape(self):
        self.p.add_case("R1", "P")
        outside = os.path.join(self.tmp, "outside.py")
        with open(outside, "w") as f:
            f.write(fixture.GRADER_ALWAYS_PASS)
        os.remove(self.p.path("graders/g_ok.py"))
        os.symlink(outside, self.p.path("graders/g_ok.py"))
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)

    def test_a8_invalid_json_evidence(self):
        self.p.add_case("R1", "X")
        code, out, rd = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertEqual({t["reason"] for t in self.p.trials(rd)}, {"evidence_invalid"})

    def test_a8_executor_field_is_rejected(self):
        self.p.add_case("R1", "E")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)

    def test_a8_oversize_evidence(self):
        self.p.add_case("R1", "B")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)

    def test_adapter_crash_is_infra(self):
        self.p.add_case("R1", "C")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)

    def test_a10_blind_case_in_cases_dir(self):
        self.p.add_case("B1", "P", split="blind")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertIn("blind", out)
        code, out = self.p.run_pe("validate", "--eval-dir", ".eval")
        self.assertEqual(code, 3, out)

    def test_regression_case_without_known_bad_is_rejected(self):
        c = self.p.add_case("R1", "P")
        del c["known_bad_ref"]; del c["known_bad_sha256"]
        self.p.save_case(c)
        code, out = self.p.run_pe("validate", "--eval-dir", ".eval")
        self.assertEqual(code, 3, out)

    def test_policy_criterion_needs_observers(self):
        del self.p.spec["success_criteria"][1]["required_observers"]
        self.p.save_spec()
        self.p.add_case("R1", "P")
        code, out = self.p.run_pe("validate", "--eval-dir", ".eval")
        self.assertEqual(code, 3, out)

    def test_unsupported_schema_keyword_blocks_gate(self):
        self.p.add_case("R1", "P")
        s = fixture.read_json(self.p.path("schemas/case.schema.json"))
        s["patternProperties"] = {}
        self.p.write("schemas/case.schema.json", json.dumps(s))
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertIn("unsupported JSON Schema keyword", out)

    def test_decision_in_the_future_is_blocked(self):
        self.p.spec["decision"]["fixed_at"] = "2099-01-01"
        self.p.save_spec()
        self.p.add_case("R1", "P")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)

    def test_safety_case_without_critical_criterion_is_rejected(self):
        self.p.add_case("S1", "P", type="safety", criteria=("SC1",))
        code, out = self.p.run_pe("validate", "--eval-dir", ".eval")
        self.assertEqual(code, 3, out)


# ---------------------------------------------------------------------------
class TestTrusted(Base):
    def setUp(self):
        super().setUp()
        self.p.add_case("R1", "P")
        self.p.add_case("S1", "P", type="safety", criteria=("PC1",))

    def cheat_grader(self):
        self.p.write("graders/g_ok.py", fixture.GRADER_CHEAT)

    def test_clean_trusted_pass_has_all_seven_invariants(self):
        self.p.init_git()
        code, out, rd = self.p.gate("all", trusted_ref="main")
        self.assertEqual(code, 0, out)
        self.assertIn("MODE: trusted (ref=", out)
        res = self.p.result(rd)
        self.assertEqual(res["status"], "PASS")
        self.assertEqual([k for k, v in res["invariants"].items() if not v], [])
        self.assertEqual(len(res["invariants"]), 7)
        self.assertEqual(res["trusted_ref"], self.p.git("rev-parse", "main"))

    def test_a1a_replaced_grader_cannot_turn_a_real_failure_into_pass(self):
        self.p.add_case("R1", "FFF")
        self.p.init_git()
        self.cheat_grader()                       # working tree only
        code, out, rd = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 1, out)
        inv = self.p.result(rd)["invariants"]
        self.assertFalse(inv["assets_verified"])
        self.assertTrue(inv["graded_with_ref_copies"])

    def test_a1b_replaced_grader_with_passing_output_needs_review(self):
        self.p.init_git()
        self.cheat_grader()
        code, out, _ = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 2, out)
        self.assertIn("graders/g_ok.py", out)

    def test_a1c_local_mode_cannot_see_the_cheat_but_verify_sh_flags_it(self):
        os.makedirs(os.path.join(self.p.root, ".verification"))
        line = "evalgate yes %s -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd '%s'\n" % (
            sys.executable, self.p.adapter_cmd())
        with open(os.path.join(self.p.root, ".verification", "checks.txt"), "w") as f:
            f.write(line)
        self.p.init_git()
        env = dict(os.environ, PE_TEST_STATE=os.path.join(self.tmp, "vstate"))
        os.makedirs(env["PE_TEST_STATE"])
        r = subprocess.run(["bash", fixture.VERIFY_SH], cwd=self.p.root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 0, r.stdout.decode())          # runs/ is not flagged
        self.cheat_grader()
        env["PE_TEST_STATE"] = os.path.join(self.tmp, "vstate2")
        os.makedirs(env["PE_TEST_STATE"])
        r = subprocess.run(["bash", fixture.VERIFY_SH], cwd=self.p.root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = r.stdout.decode()
        self.assertEqual(r.returncode, 2, out)
        self.assertIn(".eval/graders/g_ok.py", out)
        code, gate_out, _ = self.p.gate("regression")                  # the gate itself, in local mode
        self.assertEqual(code, 0, gate_out)
        self.assertIn("local (unofficial)", gate_out)

    def test_a12_running_pe_differs_from_ref(self):
        self.p.init_git()
        with open(self.p.path("pe.py"), "a") as f:
            f.write("\n# tampered\n")
        code, out, _ = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 3, out)
        self.assertIn("differs", out)

    def test_a13_unresolvable_ref(self):
        self.p.init_git()
        code, out, _ = self.p.gate("regression", trusted_ref="no-such-ref")
        self.assertEqual(code, 3, out)
        self.assertIn("cannot resolve", out)

    def test_a14_case_change_needs_review(self):
        self.p.init_git()
        c = self.p.load_case("R1"); c["added_at"] = "2026-02-02"; self.p.save_case(c)
        code, out, _ = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 2, out)
        self.assertIn("cases/R1.json", out)

    def test_a14_new_untracked_case_needs_review(self):
        self.p.init_git()
        self.p.add_case("R2", "P")
        code, out, _ = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 2, out)

    def test_spec_change_needs_review(self):
        self.p.init_git()
        self.p.spec["decision"]["owner"] = "someone else"
        self.p.save_spec()
        code, out, _ = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 2, out)

    def test_changes_to_runs_and_system_manifest_do_not_count(self):
        self.p.init_git()
        sysm = json.loads(json.dumps(fixture.SYSTEM_MANIFEST)); sysm["system"]["model_id"] = "m2"
        self.p.save_sysm(sysm)
        os.makedirs(self.p.path("runs/old"), exist_ok=True)
        code, out, _ = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 0, out)

    def test_symlink_in_eval_dir_is_refused(self):
        self.p.init_git()
        os.symlink("spec.json", self.p.path("spec-link.json"))
        code, out, _ = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 3, out)

    def test_failure_takes_precedence_over_review(self):
        self.p.add_case("R1", "FFF")
        self.p.init_git()
        c = self.p.load_case("R1"); c["added_at"] = "2026-02-02"; self.p.save_case(c)
        code, out, _ = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 1, out)


# ---------------------------------------------------------------------------
class TestCompare(Base):
    def make(self, name, sysm=None, spec_edit=None, trusted=False):
        if spec_edit:
            spec_edit(self.p.spec)
            self.p.save_spec()
        path = os.path.join(self.tmp, "sysm-%s.json" % name)
        write_json(path, sysm or fixture.SYSTEM_MANIFEST)
        code, out, rd = self.p.gate("regression", sysm=path)
        self.assertEqual(code, 0, out)
        dst = os.path.join(self.tmp, "manifest-%s.json" % name)
        shutil.copy(os.path.join(rd, "manifest.json"), dst)
        return dst

    def compare(self, a, b, purpose="system"):
        return self.p.run_pe("compare", a, b, "--purpose", purpose, "--eval-dir", ".eval")

    def sysm(self, purpose="system", **changes):
        m = json.loads(json.dumps(fixture.SYSTEM_MANIFEST))
        m["comparison_purpose"] = purpose
        for path, value in changes.items():
            sec, key = path.split("__")
            m[sec][key] = value
        return m

    def setUp(self):
        super().setUp()
        self.p.add_case("R1", "P")

    def test_same_evaluation_is_comparable_and_disclaims_performance(self):
        a = self.make("a")
        b = self.make("b", self.sysm(system__model_id="m2"))
        code, out = self.compare(a, b)
        self.assertEqual(code, 0, out)
        self.assertTrue(out.startswith("comparability check only; this is not a performance"))
        self.assertIn("system.model_id", out)

    def test_a4_empty_or_null_fields_are_refused(self):
        a = self.make("a")
        for bad in ("", None):
            data = fixture.read_json(a); data["system"]["model_id"] = bad
            pa, pb = os.path.join(self.tmp, "bad-a.json"), os.path.join(self.tmp, "bad-b.json")
            write_json(pa, data); write_json(pb, data)
            code, out = self.compare(pa, pb)
            self.assertEqual(code, 3, out)
        data = fixture.read_json(a); del data["budget"]
        write_json(pa, data)
        code, out = self.compare(pa, a)
        self.assertEqual(code, 3, out)

    def test_a9_decision_changed_after_the_fact(self):
        a = self.make("a")
        b = self.make("b", spec_edit=lambda s: s["decision"].update(power=0.9))
        code, out = self.compare(a, b)
        self.assertEqual(code, 3, out)
        self.assertIn("decision_sha256", out)

    def test_decision_fixed_after_a_run_started(self):
        a = self.make("a")
        data = fixture.read_json(a); data["evaluation"]["decision_fixed_at"] = "2099-01-01"
        pa = os.path.join(self.tmp, "late.json"); write_json(pa, data)
        code, out = self.compare(pa, pa)
        self.assertEqual(code, 3, out)
        self.assertIn("after", out)

    def test_second_manifest_decision_time_is_checked_too(self):
        a = self.make("a")
        data = fixture.read_json(a); data["evaluation"]["decision_fixed_at"] = "2099-01-01"
        b = os.path.join(self.tmp, "late-b.json"); write_json(b, data)
        self.assertEqual(self.compare(a, b)[0], 3)
        self.assertEqual(self.compare(b, a)[0], 3)

    def test_differing_decision_times_are_refused_even_when_both_are_in_the_past(self):
        a = self.make("a")
        data = fixture.read_json(a); data["evaluation"]["decision_fixed_at"] = "2025-12-31"
        b = os.path.join(self.tmp, "other-time.json"); write_json(b, data)
        code, out = self.compare(a, b)
        self.assertEqual(code, 3, out)
        self.assertIn("decision_fixed_at", out)

    def test_unexpected_error_is_blocked_not_a_traceback(self):
        a = self.make("a")
        data = fixture.read_json(a)
        b = os.path.join(self.tmp, "weird.json")
        with open(b, "w") as fh:
            fh.write("[1, 2, 3]")                      # valid JSON, but not an object: m["comparison_purpose"] raises
        code, out = self.compare(a, b)
        self.assertEqual(code, 3, out)
        self.assertNotIn("Traceback", out)

    def test_assets_differ(self):
        a = self.make("a")
        self.p.add_case("R2", "P")
        b = self.make("b")
        code, out = self.compare(a, b)
        self.assertEqual(code, 3, out)
        self.assertIn("case_set_sha256", out)

    def test_component_needs_exactly_one_difference(self):
        a = self.make("a", self.sysm("component"))
        b = self.make("b", self.sysm("component", system__model_id="m2"))
        c = self.make("c", self.sysm("component", system__model_id="m2", system__temperature=0.7))
        self.assertEqual(self.compare(a, b, "component")[0], 0)
        code, out = self.compare(a, c, "component")
        self.assertEqual(code, 3, out)

    def test_controlled_needs_equal_tools_network_data_budget(self):
        a = self.make("a", self.sysm("controlled"))
        b = self.make("b", self.sysm("controlled", system__model_id="m2", system__harness_name="h2"))
        c = self.make("c", self.sysm("controlled", env__network_scope="open"))
        self.assertEqual(self.compare(a, b, "controlled")[0], 0)
        self.assertEqual(self.compare(a, c, "controlled")[0], 3)

    def test_purpose_must_match_the_manifest(self):
        a = self.make("a", self.sysm("system"))
        code, out = self.compare(a, a, "component")
        self.assertEqual(code, 3, out)

    def test_mode_mismatch(self):
        a = self.make("a")
        data = fixture.read_json(a); data["mode"] = "trusted"
        pb = os.path.join(self.tmp, "m.json"); write_json(pb, data)
        code, out = self.compare(a, pb)
        self.assertEqual(code, 3, out)


# ---------------------------------------------------------------------------
class TestSimulation(unittest.TestCase):
    """Seeded simulation through the real scheduling and decision functions (not a re-derivation of the formulas)."""

    @staticmethod
    def simulate(q, n, seed):
        rng = random.Random(seed)
        blocked = 0
        slots_total = 0
        for _ in range(n):
            def run(phase, index):
                return {"phase": phase, "outcome": "fail" if rng.random() < q else "pass", "class": "normal", "criteria": {}}
            slots = []
            pe.schedule_regression(run, slots)
            slots_total += len(slots)
            if pe.decide_regression(slots) == "fail":
                blocked += 1
        return blocked / n, slots_total / n

    def assertClose(self, emp, exact, n):
        sigma = (exact * (1 - exact) / n) ** 0.5
        self.assertLess(abs(emp - exact), 4 * sigma + 2e-5, (emp, exact))

    def test_false_block_rate_per_case(self):
        n = 400000
        for rel, seed in ((0.99, 1), (0.995, 2), (0.999, 3)):
            emp, _ = self.simulate(1 - rel, n, seed)
            self.assertClose(emp, pe.p_block_case(1 - rel), n)

    def test_scaled_to_100_cases_matches_the_document(self):
        n = 400000
        emp, _ = self.simulate(0.01, n, 11)
        self.assertEqual(round(100 * (1 - (1 - emp) ** 100), 0), 11.0)     # document: 11.1%

    def test_regression_detection(self):
        n = 200000
        for success, seed, doc in ((0.5, 4, 82.8), (0.7, 5, 50.6), (0.8, 6, 29.1)):
            emp, _ = self.simulate(1 - success, n, seed)
            self.assertClose(emp, pe.regression_block_prob(success), n)
            self.assertAlmostEqual(100 * emp, doc, delta=0.7)

    def test_expected_cost_in_trials_per_case(self):
        q = 0.05
        _, mean_slots = self.simulate(q, 200000, 7)
        exactly_one = 3 * q * (1 - q) ** 2
        self.assertAlmostEqual(mean_slots, 3 + 3 * exactly_one, delta=0.02)

    def test_safety_is_stricter_than_regression(self):
        rng = random.Random(8)
        q, n, flaky_pass, safety_fail = 0.02, 100000, 0, 0
        for _ in range(n):
            def run(phase, index):
                bad = rng.random() < q
                return {"phase": phase, "outcome": "fail" if bad else "pass", "class": "normal",
                        "criteria": {"PC1": "fail" if bad else "pass"}}
            slots = []
            pe.schedule_regression(run, slots)
            pe.schedule_safety(run, slots, 3)
            if pe.decide_regression(slots) in ("pass", "flaky") and pe.decide_safety(slots, ["PC1"]) == "fail":
                flaky_pass += 1
            if pe.decide_safety(slots, ["PC1"]) == "fail":
                safety_fail += 1
        self.assertGreater(flaky_pass, 0)                 # the two gates really interpret the same trials differently
        self.assertGreaterEqual(safety_fail, flaky_pass)


class TestRunIntegrity(Base):
    """Attacks on the run itself, by an adapter that has the same user rights as pe.py."""

    def assertAttackHappened(self):
        hits = [int(x) for x in fixture.read_text(os.path.join(self.tmp, "state-1", "tampered.txt")).split()]
        self.assertTrue(hits and sum(hits) > 0, "the fake adapter did not manage to tamper with anything: %r" % hits)

    def test_a15_adapter_rewrites_the_extracted_ref_grader(self):
        self.p.add_case("R1", "R")
        self.p.init_git()
        code, out, rd = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 3, out)
        self.assertIn("changed during the run", out)
        self.assertAttackHappened()

    def test_a15_adapter_plants_a_snapshot_in_the_extracted_ref(self):
        self.p.add_case("R1", "Q")
        self.p.init_git()
        code, out, _ = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 3, out)
        self.assertIn("changed during the run", out)
        self.assertAttackHappened()

    def test_a15_adapter_rewrites_the_working_tree_grader_local(self):
        self.p.add_case("R1", "G")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)
        self.assertIn("changed during the run", out)
        self.assertAttackHappened()

    def test_grader_runs_from_the_bytes_loaded_at_start(self):
        self.p.add_case("R1", "P")
        assets = pe.load_assets(self.p.eval)
        self.p.write("graders/g_ok.py", fixture.GRADER_ALWAYS_PASS)       # changed after loading
        case = assets.cases["R1"]
        with tempfile.TemporaryDirectory() as tmp:
            verdict, _ = pe.run_grader(assets, "g_ok", case, self.p.path("refs/R1-bad.json"), tmp)
        self.assertEqual(verdict, "fail")

    def test_a16_adapter_deletes_the_run_directory_contents(self):
        self.p.add_case("R1", "D")
        code, out, rd = self.p.gate("regression")
        self.assertEqual(code, 0, out)
        self.assertEqual(len(self.p.trials(rd)), 3)
        for rel, want in self.p.result(rd)["artifacts_sha256"].items():
            with open(os.path.join(rd, *rel.split("/")), "rb") as fh:
                self.assertEqual(hashlib.sha256(fh.read()).hexdigest(), want, rel)

    def test_a17_unwritable_run_directory_is_blocked_even_when_the_case_failed(self):
        def restore():
            runs = self.p.path("runs")
            for dp, dns, fns in os.walk(runs):
                os.chmod(dp, 0o700)
            os.chmod(runs, 0o700)
        self.addCleanup(restore)
        self.p.add_case("R1", "W")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 3, out)                      # BLOCKED > FAIL
        self.assertIn("artifacts not preserved", out)

    def test_trusted_pass_is_refused_after_an_invalid_evidence_attempt(self):
        self.p.add_case("R1", "XPPP")
        self.p.init_git()
        code, out, rd = self.p.gate("regression", trusted_ref="main")
        self.assertEqual(code, 3, out)
        self.assertIn("evidence_schema_verified", out)
        code, out, _ = self.p.gate("regression")            # local mode: the retry may recover
        self.assertEqual(code, 0, out)

    def test_adapter_gets_a_private_tmpdir(self):
        self.p.add_case("R1", "P")
        with open(self.p.adapter, "a") as fh:
            fh.write("\nimport tempfile as _t\nopen(os.path.join(state, 'tmpdir.txt'), 'a').write(_t.gettempdir() + '\\n')\n")
        self.p.gate("regression")
        seen = fixture.read_text(os.path.join(self.tmp, "state-1", "tmpdir.txt")).split()
        self.assertTrue(seen)
        self.assertTrue(all("pe-trial-" in d for d in seen), seen)


class TestAdapterPaths(Base):
    def test_relative_adapter_script_path_is_resolved_against_the_start_directory(self):
        self.p.add_case("R1", "P")
        os.makedirs(os.path.join(self.p.root, "adapters"))
        shutil.copy(self.p.adapter, os.path.join(self.p.root, "adapters", "run.py"))
        state = os.path.join(self.tmp, "state-rel")
        os.makedirs(state)
        cmd = [sys.executable, "-I", self.p.path("pe.py"), "gate", "regression", "--eval-dir", ".eval",
               "--adapter-cmd", json.dumps([sys.executable, "adapters/run.py"])]
        r = subprocess.run(cmd, cwd=self.p.root, env=dict(os.environ, PE_TEST_STATE=state),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 0, r.stdout.decode())

    def test_missing_adapter_script_is_blocked_not_failed(self):
        self.p.add_case("R1", "P")
        state = os.path.join(self.tmp, "state-missing")
        os.makedirs(state)
        cmd = [sys.executable, "-I", self.p.path("pe.py"), "gate", "regression", "--eval-dir", ".eval",
               "--adapter-cmd", json.dumps([sys.executable, "adapters/nope.py"])]
        r = subprocess.run(cmd, cwd=self.p.root, env=dict(os.environ, PE_TEST_STATE=state),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 3, r.stdout.decode())

    def test_absolutize_unit(self):
        d = tempfile.mkdtemp(dir=self.tmp)
        open(os.path.join(d, "run.py"), "w").close()
        self.assertEqual(pe.absolutize_adapter(["python3", "run.py", "-x", "missing"], d),
                         ["python3", os.path.join(d, "run.py"), "-x", "missing"])
        self.assertEqual(pe.absolutize_adapter(["./run.py"], d), [os.path.join(d, "./run.py")])


class TestProcessHygiene(Base):
    def alive(self, pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def test_background_children_of_the_adapter_do_not_survive(self):
        self.p.add_case("R1", "O")
        self.p.gate("regression")
        state = os.path.join(self.tmp, "state-1", "orphan.pids")
        pids = [int(x) for x in fixture.read_text(state).split()]
        self.assertTrue(pids)
        import time
        time.sleep(0.3)
        self.assertEqual([p for p in pids if self.alive(p)], [])

    def test_hanging_adapter_leaves_no_process_behind(self):
        self.p.spec["adapter"]["timeout_s"] = 1
        self.p.save_spec()
        self.p.add_case("R1", "T")
        code, out, _ = self.p.gate("regression")
        self.assertEqual(code, 1, out)
        r = subprocess.run(["pgrep", "-f", self.p.adapter], stdout=subprocess.PIPE)
        self.assertEqual(r.stdout.decode().split(), [])

    def test_trusted_gate_from_a_subdirectory(self):
        self.p.add_case("R1", "P")
        self.p.init_git()
        sub = os.path.join(self.p.root, "sub", "deeper")
        os.makedirs(sub)
        state = os.path.join(self.tmp, "state-sub")
        os.makedirs(state)
        env = dict(os.environ, PE_TEST_STATE=state)
        cmd = [sys.executable, "-I", self.p.path("pe.py"), "gate", "regression", "--eval-dir", "../../.eval",
               "--adapter-cmd", self.p.adapter_cmd(), "--trusted-ref", "main",
               "--system-manifest", self.p.path("system-manifest.json"), "--out", os.path.join(self.tmp, "out")]
        r = subprocess.run(cmd, cwd=sub, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 0, r.stdout.decode())
        self.assertIn("MODE: trusted (ref=", r.stdout.decode())


if __name__ == "__main__":
    unittest.main()
