# portable-verification

[English](README.md)

작고 의존성이 적은 실행기를 가진 에이전트 스킬 두 개입니다. 상태는 에이전트가 아니라 스크립트가 판정합니다.

| 스킬 | 답하는 질문 | 실행기 | 성숙도 |
|---|---|---|---|
| `portable-verification` | 이 변경이 동작하는가? | `verify.sh`(bash + perl)가 `.verification/checks.txt`에 선언된 검사를 실행 | 테스트됨. v0.1.0으로 릴리스 |
| `portable-eval` | 이 에이전트 시스템이 성공 기준을 충족하는가? | `pe.py`(Python 3.9+, 표준 라이브러리만)가 `.eval/`에 선언된 회귀·안전 게이트를 실행 | **실험적(0.x).** Portable-Eval v2.1 설계 중 소규모 팀용 부분집합의 초기 구현 |

두 스킬은 일부러 분리했습니다. 읽는 시점(매 변경 vs. 프롬프트·모델·도구 변경), 신뢰 요건, 성숙도가 다르기 때문입니다. 만나는 곳은 한 곳입니다. eval 게이트는 `checks.txt`의 한 줄입니다.

**보장하는 것:** 선언된 검사가 매번 같은 방식으로 실행되고, 출력이 저장되며, 상태가 에이전트의 자기 요약이 아니라 스크립트에서 나옵니다.

**보장하지 않는 것:** 조작을 막지는 못합니다. `checks.txt`, `verify.sh`, 평가 자산, 환경변수를 고칠 수 있는 에이전트나 사람은 결과를 바꿀 수 있습니다. 스크립트는 그런 수정을 발견했을 때 `NEEDS_REVIEW`를 낼 뿐입니다. 실제 강제는 필수 상태 검사로 지정한 CI와, 표시된 변경을 읽는 사람이 맡습니다.

## 설치

`bash`, `git`, `perl`이 필요하고, `portable-eval`은 `python3` 3.9 이상도 필요합니다. 설치기는 `curl`, `tar`, `gzip`, 그리고 `shasum` 또는 `sha256sum`도 필요합니다.

### A. clone 후 심기

```bash
git clone https://github.com/Sooparkle/portable-verification.git
cd portable-verification && git checkout v0.2.0
bash skills/portable-verification/scripts/plant.sh --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
bash skills/portable-eval/scripts/plant.sh --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
```

`git checkout v0.2.0`을 하면 detached HEAD 상태가 됩니다. 정상입니다. 필요한 스킬만 심으면 됩니다.

### B. 설치기 (고정된 sha256 검사)

내려받아 읽고 실행하는 방법을 권장합니다. `--skill`은 `verification`(기본값), `eval`, `both` 중 하나입니다.

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/Sooparkle/portable-verification/v0.2.0/install.sh
less install.sh
bash install.sh --skill both --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
```

읽지 않은 코드를 실행하게 되지만, 파이프로 바로 실행할 수도 있습니다.

```bash
curl -fsSL https://raw.githubusercontent.com/Sooparkle/portable-verification/v0.2.0/install.sh | bash -s -- --skill both --target ~/work/my-app --agent claude
```

설치기는 선택한 스킬마다 릴리스 압축파일을 받아 `install.sh` 안에 적힌 값과 sha256을 비교합니다. 선택한 모든 스킬에 `plant.sh --check`를 먼저 실행하고, 그 뒤에야 프로젝트에 씁니다. 다운로드가 실패하거나, 해시가 다르거나, 사전 점검이 실패하면 프로젝트를 건드리지 않고 멈춥니다(`both`를 골랐을 때도 아무것도 설치되지 않습니다). 고정된 해시는 손상되었거나 바꿔치기된 릴리스 파일을 막아 줍니다. 저장소 자체가 탈취되어 `install.sh`와 해시가 함께 바뀐 경우는 막지 못하므로, 먼저 `install.sh`를 읽는 것이 대비책입니다. 설치는 트랜잭션이 아닙니다. 쓰는 도중의 I/O 오류(디스크 가득 등)는 일부만 설치된 상태를 남길 수 있고, `plant.sh`는 멱등이라 다시 실행하면 됩니다.

## portable-verification을 프로젝트에 심는 방법

1. **위의 A 또는 B를 실행합니다.** 에이전트가 읽는 폴더를 고릅니다(아래 표). `--agent`를 생략하면 plant.sh가 `.claude/`, `.cursor/`, `.agents/`, `AGENTS.md`를 보고 추측하고, 아무것도 없으면 `.agents/skills/`를 씁니다.
2. **프로젝트에 생기는 것:**

```text
my-app/
├── .claude/skills/portable-verification/   # the skill (rules the agent reads); folder depends on --agent
├── .verification/
│   ├── checks.txt          # what must pass: YOU edit this
│   ├── feature-map.md      # how each user-facing feature is launched and driven: YOU fill this
│   ├── verify.sh           # the runner (copy)
│   ├── .plant-manifest     # version and hashes of what was installed (informational)
│   └── evidence/           # logs of each run; git-ignored
├── CLAUDE.md               # only with --pointer: a short marked block pointing at the skill
└── .github/workflows/verification.yml   # only with --ci github
```

3. **검사를 켭니다.** plant.sh는 `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `gradlew`, `pom.xml`, `pubspec.yaml`, `Makefile`을 보고 제안 줄을 주석으로 적어 둡니다. 맨 앞의 `#`을 지우기 전에는 아무것도 실행되지 않습니다. 형식은 `id required command`이고 구분자는 공백 또는 탭입니다.

```text
unit       yes  pnpm run test
typecheck  yes  pnpm run typecheck
e2e-login  yes  pnpm exec playwright test tests/e2e/login.spec.ts
lint       no   pnpm run lint
```

4. **`feature-map.md`를 채웁니다.** 사용자가 가장 많이 쓰는 기능 3~5개에 대해 실행 방법, 조작 방법, 확인할 부작용, 정리 방법을 적습니다.
5. **첫 실행과 커밋.**

```bash
bash .verification/verify.sh
```

   새 파일이 아직 커밋되지 않았으므로 첫 실행은 `NEEDS_REVIEW`입니다. 의도된 동작입니다. `checks.txt`가 바뀌면 항상 사람이 봐야 하기 때문입니다. 파일을 읽고 커밋(스킬 폴더, `.verification/`, `.gitignore`)한 뒤 다시 실행하면, 통과하는 프로젝트는 `PASS`가 됩니다.
6. **강제 연결(선택, 권장).** GitHub 브랜치 보호에서 `verify` job을 필수 상태 검사로 지정합니다. 테스트 파일을 바꾼 PR은 사람이 diff를 읽고 `tests-reviewed` 라벨을 붙이기 전까지 `NEEDS_REVIEW`로 막힙니다. 이 단계가 없으면 에이전트가 따를 때만 동작하는 지침에 머뭅니다.

**업데이트:** `git fetch --tags`, `git checkout vX.Y.Z`, 그 뒤 `--force`를 붙여 plant.sh를 다시 실행합니다. `--force`는 스킬 폴더와 `.verification/verify.sh`를 교체하고, `checks.txt`, `feature-map.md`, 이미 있는 CI 워크플로는 절대 덮어쓰지 않습니다. 새 버전과 다른 스킬 폴더나 `verify.sh`는 `--force`가 없으면 건너뜁니다.

**제거:** 스킬 폴더, `.verification/`, `.gitignore`의 `.verification/evidence/` 줄, 지시 파일에서 `portable-verification:start`와 `portable-verification:end` 사이 블록을 지웁니다.

## portable-eval (실험적)

`skills/portable-eval/docs/design-v2.1.md` 설계 중 "소규모 팀용"(8절) 부분집합의 초기 구현입니다. 도구가 약속하는 내용은 `skills/portable-eval/docs/contracts.md`에 고정되어 있고 테스트가 그것을 단언합니다. **검증된 평가 플랫폼이 아닙니다.** 출력되는 수치는 설계 문서의 공식을 따를 뿐이고, 설계 자체의 초기값도 검증되지 않았습니다.

구현된 것: spec·케이스·manifest 검증, 회귀 게이트(3회 시행, 실패하면 3회 추가, 6회 중 2회 실패면 차단), 안전 게이트(critical 기준이 한 번이라도 실패하면 FAIL), 고정된 known-bad 증거로 하는 채점기 자기 테스트, 정책 증거 검사, 실행 manifest의 비교 가능성 검사, 표본 수 계산기. 구현되지 않은 것: 시간에 따른 케이스 승격·강등, blind 세트 운영, 루브릭, LLM judge, 비열등성·우월성·동등성 검정, 이식성 검사.

심으면 `pe.py`, `schemas/`, 그리고 `REPLACE` 자리표시자가 가득한 `spec.json` / `system-manifest.json`이 들어 있는 `.eval/`이 생깁니다. 사람이 채우기 전에는 게이트가 실행을 거부합니다(BLOCKED). 채점기, 케이스, 어댑터는 직접 작성합니다(어댑터는 평가 자산이 아니라 평가 대상 시스템의 일부입니다).

```text
my-app/
├── .claude/skills/portable-eval/   # the skill, with docs/contracts.md and docs/design-v2.1.md
├── .eval/
│   ├── spec.json               # criteria, graders, risk tiers, decision block: YOU fill this
│   ├── system-manifest.json    # model, harness, prompt hash, tools, budget: YOU fill this (claims)
│   ├── cases/  graders/  refs/ # YOUR cases, graders and pinned known-bad evidence
│   ├── schemas/  pe.py         # the tool and its schemas (copies)
│   └── runs/                   # trial records, evidence, manifests; git-ignored
└── .github/workflows/eval.yml  # only with --ci github: the trusted gate
```

```bash
python3 -I .eval/pe.py validate --eval-dir .eval
python3 -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd '["python3","-I","adapters/run.py"]'
python3 -I .eval/pe.py gate all --eval-dir .eval --adapter-cmd '["python3","-I","adapters/run.py"]' --trusted-ref origin/main
```

**두 가지 모드와 그 이유.** 로컬 실행은 작업 트리의 `.eval/`을 쓰고 `MODE: local (unofficial)`을 출력합니다. 평가 대상 코드를 바꾸는 쪽이 채점기도 바꿀 수 있으므로 이것은 판정이 아니라 피드백입니다. trusted 실행(`--trusted-ref`)은 보호된 ref에서 추출한 사본으로 채점하고, 실행 중인 `pe.py`가 그 ref의 `pe.py`와 다르면 실행을 거부하며, 작업 트리의 평가 자산을 ref의 것과 비교합니다. 차이가 있으면 결과는 `NEEDS_REVIEW`까지만 가능하고 `PASS`가 될 수 없습니다. trusted PASS에는 7개 불변조건이 필요합니다(`result.json`에 기록). 우선순위: BLOCKED > FAIL > NEEDS_REVIEW > PASS.

어댑터는 `pe.py`와 같은 사용자 권한으로 실행됩니다. 도구는 시작할 때 읽어 둔 바이트로 채점기를 실행하고, 매 채점 전에 자산 해시를 다시 확인하고, 시행 기록은 마지막에만 씁니다. 그래서 실행 중에 채점기를 고치거나 기록을 지우는 어댑터는 BLOCKED로 끝납니다. 다만 이것은 격리가 아니라 탐지입니다. 공식 판정이 되려면 평가 대상 시스템을 다른 OS 사용자나 별도 컨테이너에서 실행해야 하고, 도구는 그것을 확인할 수 없습니다(`docs/contracts.md` 1절).

verification과는 `checks.txt`의 한 줄로 연결하고(로컬 피드백), trusted 게이트는 CI에서 실행합니다.

```text
eval-regression  yes  python3 -I .eval/pe.py gate regression --eval-dir .eval --adapter-cmd '["python3","-I","adapters/run.py"]'
```

`.eval/` 아래(spec, 케이스, 채점기, 스키마, refs, snapshots, `pe.py`)가 바뀌면 `verify.sh`는 `NEEDS_REVIEW`를 냅니다. 공식 게이트는 `references/ci-eval-trusted.yml`에 있고, PR의 기준 커밋에서 가져온 `pe.py`와 자산으로 실행됩니다. 그 워크플로 자체도 PR이 고칠 수 있으므로 `.github/`와 `.eval/`을 CODEOWNERS와 코드 오너 필수 리뷰(`references/CODEOWNERS.example`)로 보호하고 그 job을 필수 검사로 지정해야 합니다. 이것은 저장소 설정이라 도구가 강제하지 못합니다.

안전 게이트를 통과했다고 안전하다는 주장이 되지는 않습니다. 게이트는 위험 family 수를 출력하고, 독립적인 family가 충분해질 때까지(5% 상한에 59개, 독립 가정) `SAFETY_CLAIM: not demonstrated`라고 말합니다.

## `--agent` 값 선택

| 도구 | `--agent` | 스킬 폴더 | 공식 문서 확인 | 도구에서 스킬 로딩 시험 |
|---|---|---|---|---|
| Claude Code | `claude` | `.claude/skills/` | 예, 초안 작성자가 확인 (code.claude.com) | 아니오 |
| Codex | `agents` | `.agents/skills/` | 예, 초안 작성자가 확인 (developers.openai.com) | 아니오 |
| Cursor | `cursor` | `.cursor/skills/` | 아니오 | 아니오 |
| GitHub Copilot | `github` | `.github/skills/` (`.claude/skills`, `.agents/skills`도 읽음) | 아니오, 2차 자료만 | 아니오 |

모든 행에서 "시험"은 plant.sh가 해당 폴더에 파일을 놓는다는 것(테스트로 확인)만 뜻합니다. 각 도구가 그 스킬을 실제로 불러오는지는 여기서 확인하지 않았습니다. `--agent`는 하나만 지정하세요. 여러 폴더를 읽는 도구에서는 스킬이 두 번 보일 수 있습니다.

## 상태

| 종료 코드 | 상태 | 의미 |
|---|---|---|
| 0 | PASS | 필수 검사가 모두 통과했고, 표시된 테스트/설정 파일이 바뀌지 않았음(또는 사람이 `TESTS_REVIEWED=1` 설정) |
| 1 | FAIL | 필수 검사가 실패했거나 시간 초과. `TESTS_REVIEWED=1`로도 바뀌지 않음 |
| 2 | NEEDS_REVIEW | 검사는 통과했지만 테스트 파일, 테스트 설정, `.verification/checks.txt`·`verify.sh`, `.eval/` 자산이 바뀌었거나 변경 범위를 알 수 없음 |
| 3 | BLOCKED | 검사 파일이 없거나 잘못됨, 필수 검사 없음, 필요한 도구 없음 |
| 4 | NOT RUN | 선언된 검사가 없거나 실행이 중단됨 |

`pe.py`도 같은 종료 코드를 씁니다. 1은 평가 대상 시스템이 실패했다는 뜻, 3은 도구가 판정할 수 없었다는 뜻(잘못된 자산, 채점기 오류, 자기 테스트 실패, 정책 증거 누락, 실행 불가 시행), 4는 선택된 케이스가 없다는 뜻입니다.

## 한계

- `TESTS_REVIEWED=1`은 사람이 설정하는 신호입니다. 로컬에서는 누구나 설정할 수 있습니다. CI에서는 라벨에서 오며, 라벨을 붙일 수 있는 사람은 관문을 풀 수 있습니다.
- 파일 패턴이 덮지 못하는 방식의 약화(예: `package.json` 안의 `test` 스크립트 수정)는 감지하지 못합니다. 필요하면 `FLAG_PATH_REGEX`에 그 파일을 추가하세요. 오탐이 늘어납니다.
- 테스트를 자주 고치는 팀은 `NEEDS_REVIEW`를 자주 보게 되고, 결국 무시하게 될 수 있습니다.
- 비밀값 제거는 환경변수 값(이름에 TOKEN, SECRET, KEY, PASSWORD, PASSWD, CREDENTIAL, COOKIE 포함, 6자 이상), Authorization/Cookie 헤더, Bearer 토큰만 다룹니다. 파일에 하드코딩된 값, 환경변수가 아닌 비밀값, 스크린샷은 볼 수 없습니다.
- `CHECK_TIMEOUT`은 `timeout` 또는 `gtimeout`이 필요합니다. macOS에는 기본으로 없으므로(coreutils 설치) 없으면 실행이 `BLOCKED`가 됩니다.
- `SKILL.md`의 Tier B(실제 앱 구동)와 Tier C(독립 리뷰)는 지침입니다. 스크립트가 강제하는 것은 `checks.txt`에 선언된 검사뿐입니다.
- portable-eval: 환경 격리와 정책 관측 장치는 어댑터가 하는 주장입니다. 도구는 주장된 내용만 확인합니다. 로컬 결과는 비공식입니다. 공식 결과는 도구가 강제할 수 없는 저장소 설정에 달려 있습니다. 게이트 확률은 케이스 독립과 시행당 신뢰도 일정을 가정하며, 공통 장애가 있으면 이 가정이 깨집니다.
- 이 조합이 출처 하나만 쓰는 것보다 낫다는 측정 결과는 없습니다.
- Windows는 시험하지 않았습니다(WSL이나 Git Bash는 각자 책임으로).

## 여기서 검증한 것

`BASH_BIN=/bin/bash PYTHON_BIN=python3 bash tests/run.sh`를 직접 실행해 보세요. bash·Python 버전과 개수가 출력됩니다.

| 항목 | 상태 |
|---|---|
| macOS(bash 3.2.57, 시스템 Python 3.9.6)에서 bash 시나리오 테스트, python 단위 테스트, 적대적 매트릭스 A1-A14 | 개수는 해당 릴리스의 CHANGELOG 참고 |
| Ubuntu와 더 새로운 bash/Python에서 같은 테스트 | 변경을 push하면 GitHub Actions가 실행. CI 로그 참고 |
| 스키마 검증기와 `jsonschema` 교차 검증 | 로컬의 일회용 venv와 CI에서 실행. 라이브러리가 없으면 건너뜀 |
| 변이 검사(규칙을 일부러 망가뜨리면 테스트가 실패하는지) | 직접 실행. 결과는 CHANGELOG에 있음 |
| 실제 `timeout` 바이너리 | Ubuntu CI에서만. macOS에서는 종료 코드 124를 내는 대체 스크립트 사용 |
| `agentskills validate` | 실행 안 함 |
| 프로젝트에 심어지는 워크플로(`ci-github-actions.yml`, `ci-eval-trusted.yml`) | 실행 안 함 |
| 어댑터 뒤의 실제 LLM 에이전트, LLM judge, blind 세트 | 구현 안 함, 실행 안 함 |
| 각 에이전트 도구에서 스킬 로딩 | 시험 안 함 |
| Windows | 시험 안 함 |

## 출처와 라이선스

portable-verification이 가져온 아이디어와 각각의 확인 방법은 `skills/portable-verification/SOURCES.md`, portable-eval의 근거는 `skills/portable-eval/docs/design-v2.1.md` 10절을 보세요. SOURCES.md는 자체 주장 중 여기서 검증하지 않은 것도 밝히고 있습니다. MIT 라이선스이며 `LICENSE`를 보세요. 재배포 전에 그 파일에 적힌 출처들의 라이선스를 확인하세요.
