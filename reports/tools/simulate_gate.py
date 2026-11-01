import importlib.util, random, math
spec = importlib.util.spec_from_file_location("pe", __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "..", "..", "skills", "portable-eval", "scripts", "pe.py"))
pe = importlib.util.module_from_spec(spec); spec.loader.exec_module(pe)
def simulate(q, n, seed):
    rng = random.Random(seed); blocked = 0
    for _ in range(n):
        def run(phase, index):
            return {"phase": phase, "outcome": "fail" if rng.random() < q else "pass", "class": "normal", "criteria": {}}
        slots = []; pe.schedule_regression(run, slots)
        blocked += pe.decide_regression(slots) == "fail"
    return blocked / n
print("| reliability | samples | seed | simulated per case | exact per case | z | scaled to 100 cases (sim / exact / document) |")
print("|---|---|---|---|---|---|---|")
for rel, seed, doc in ((0.99, 101, "11.1%"), (0.995, 102, "2.9%"), (0.999, 103, "0.1%")):
    n = 2000000
    emp = simulate(1 - rel, n, seed); ex = pe.p_block_case(1 - rel)
    z = (emp - ex) / math.sqrt(ex * (1 - ex) / n)
    print("| %s | %d | %d | %.5f%% | %.5f%% | %+.2f | %.1f%% / %.1f%% / %s |" % (rel, n, seed, 100*emp, 100*ex, z, 100*(1-(1-emp)**100), 100*pe.false_block_rate(rel,100), doc))
