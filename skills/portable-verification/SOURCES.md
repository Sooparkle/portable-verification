# Sources

No upstream file is copied verbatim. All text is a paraphrased adaptation.
"Read" = the source text itself was opened. "Mirror" = a third-party copy of the source text.
"Secondary" = a summary written by someone else.

| Part of this skill | Idea taken | Author and source | How it was checked |
|---|---|---|---|
| Tier B, feature map, cleanup rule | Drive the real app like a user; no internal setters; check side effects; stop only what you started; keep evidence | Lauren Tan (poteto), cursor/plugins pstack: create-verification-skill, prove-it-works (MIT) | Mirror (skills.cat) and secondary summary |
| BLOCKED status | Say exactly what blocked the work | pstack maintain-verification-skill | Mirror |
| Prevention layer order | Move a repeated mistake to structure/types, then lint, then test, then prose | pstack /correct | Secondary |
| measured / inferred / guess | Label each claim by evidence | pstack poteto-mode | Secondary |
| Tier A, seam rule, debug tags, credentials | Tight red-capable loop before any hypothesis; minimise; regression test only at a correct seam; tagged debug logs; secrets via env vars and redaction | Matt Pocock, mattpocock/skills diagnosing-bugs (MIT) | Read (SKILL.md body; the page may lag the repo) |
| Report: summary view, before/after evidence, door, blast radius | PR body shape | Matt Pocock, mattpocock/skills pr | Read |
| Tier C spec axis | Review against the originating spec, separate from standards | Matt Pocock, mattpocock/skills code-review | README description only |
| Tier C independence, 3-attempt limit, "How to revert", CI gate | Fresh-context subagent review; step back after three rounds; Testing/Risk/How to revert in the PR template; require CI | Anthropic, "How the Claude Code team does code review" | Read from a copy supplied by the skill's author. No primary URL was located when this repository was prepared, so readers cannot check it against the original; second-hand coverage exists (for example https://alexop.dev/tils/how-claude-code-team-does-code-review) |
| Harness app runner in Tier B | Claude Code /verify builds and runs the app to confirm a change | code.claude.com/docs/en/skills | Read (search excerpt) |
| verify.sh, NEEDS_REVIEW on test/config changes | Own design. Motivation: agents edit or special-case tests when spec and tests conflict | ImpossibleBench (Zhong, Raghunathan, Carlini; ICLR 2026, arXiv 2510.20270) | Secondary; original paper not read |
| Folder name equals `name` | Required by the format | agentskills.io/specification | Read |

Not verified by the maintainers of this repository: the statement above that no upstream text is copied verbatim, and the "How it was checked" column. They come from the original author's draft. Treat them as claims, not audited facts.

Licenses: mattpocock/skills is MIT; cursor/plugins pstack is MIT. If any text is later copied verbatim, keep both copyright notices.
