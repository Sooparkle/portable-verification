# Verification report
<!-- Paste into the PR body. Mark every result line [measured], [inferred], or [guess]. -->

## Summary
<!-- The smallest view that shows the change: call tree, file tree, diff sketch, or pseudocode. -->

## Status
- verify.sh STATUS line, verbatim:
- Evidence directory:
- Flagged test/config files: NONE | CHANGED (list each, with why it changed) | UNKNOWN

## Evidence
- Tier A (bug): command; before (red) output excerpt; after (green) output excerpt:
- Tier B (feature): user path driven; side effects observed; evidence files:
- Tier C (spec): PASS | FAIL | BLOCKED | NOT INDEPENDENT; spec or issue link; reviewer findings:

## Risk and rollback
- Door: two-way (cheap to undo) | one-way (destructive or hard to reverse), and why:
- How to revert:
- Blast radius, observed (ran it):
- Blast radius, inferred (did not run):

## Findings
- Architecture findings (no correct test seam, repeated workaround):
- Prevention (layer chosen for a repeated mistake class: structure/types, lint, test, instruction):
- Not run / known gaps:
