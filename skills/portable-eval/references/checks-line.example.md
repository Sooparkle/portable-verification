# Wiring the gate into portable-verification

`.verification/checks.txt` takes one check per line (`id required command`). Local feedback during development:

    eval-regression  yes  python3 -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd '["python3","-I","adapters/run.py"]'
    eval-safety      yes  python3 -I .eval/pe.py gate safety     --eval-dir .eval --adapter-cmd '["python3","-I","adapters/run.py"]'

These run in **local mode**: the status line says `MODE: local (unofficial)` and the working tree's graders are used.
`verify.sh` reports `NEEDS_REVIEW` when anything under `.eval/` (spec, cases, graders, schemas, refs, snapshots, pe.py) changed.
A trusted result needs `--trusted-ref` in CI; see `ci-eval-trusted.yml`. It is an official verdict only when the adapter also runs as another OS user or in a separate container (`docs/contracts.md` section 1).
`adapters/run.py` is your own adapter. It is part of the system under test, so it is not an evaluation asset.
