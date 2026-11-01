# portable-verification

[English](README.md)

에이전트 스킬과 작은 셸 실행기입니다. 변경이 통과해야 할 검사를 `.verification/checks.txt`에 선언하면, `verify.sh`가 그 검사를 실행하고 비밀값을 가린 로그를 저장한 뒤 상태를 하나 출력합니다. 에이전트는 그 상태를 그대로 보고할 뿐 스스로 판정하지 않습니다.

**보장하는 것:** 선언된 검사가 매번 같은 방식으로 실행되고, 출력이 저장되며, 상태가 에이전트의 자기 요약이 아니라 스크립트에서 나옵니다.

**보장하지 않는 것:** 조작을 막지는 못합니다. `checks.txt`, `verify.sh`, 환경변수를 고칠 수 있는 에이전트나 사람은 결과를 바꿀 수 있습니다. 스크립트는 그런 수정을 발견했을 때 `NEEDS_REVIEW`를 낼 뿐입니다. 실제 강제는 필수 상태 검사로 지정한 CI와, 표시된 변경을 읽는 사람이 맡습니다.

## 설치

`bash`, `git`, `perl`이 필요합니다. 설치기는 `curl`, `tar`, `gzip`, 그리고 `shasum` 또는 `sha256sum`도 필요합니다.

### A. clone 후 심기

```bash
git clone https://github.com/Sooparkle/portable-verification.git
cd portable-verification && git checkout v0.1.0
bash skills/portable-verification/scripts/plant.sh --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
```

`git checkout v0.1.0`을 하면 detached HEAD 상태가 됩니다. 정상입니다.

### B. 한 줄 설치기 (고정된 sha256 검사)

내려받아 읽고 실행하는 방법을 권장합니다.

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/Sooparkle/portable-verification/v0.1.0/install.sh
less install.sh
bash install.sh --target ~/work/my-app --agent claude --pointer CLAUDE.md --ci github
```

읽지 않은 코드를 실행하게 되지만, 파이프로 바로 실행할 수도 있습니다.

```bash
curl -fsSL https://raw.githubusercontent.com/Sooparkle/portable-verification/v0.1.0/install.sh | bash -s -- --target ~/work/my-app --agent claude
```

설치기는 자신과 같은 버전의 릴리스 압축파일을 받아 `install.sh` 안에 적힌 값과 sha256을 비교합니다. 다운로드가 실패하거나 해시가 다르면 프로젝트를 건드리기 전에 멈춥니다. 이는 손상되었거나 바꿔치기된 릴리스 파일을 막아 줍니다. 저장소 자체가 탈취되어 `install.sh`와 해시가 함께 바뀐 경우는 막지 못하므로, 먼저 `install.sh`를 읽는 것이 대비책입니다.

## 프로젝트에 심는 방법 (planting)

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
| 2 | NEEDS_REVIEW | 검사는 통과했지만 테스트 파일, 테스트 설정, `.verification/checks.txt`·`verify.sh`가 바뀌었거나 변경 범위를 알 수 없음 |
| 3 | BLOCKED | 검사 파일이 없거나 잘못됨, 필수 검사 없음, 필요한 도구 없음 |
| 4 | NOT RUN | 선언된 검사가 없거나 실행이 중단됨 |

## 한계

- `TESTS_REVIEWED=1`은 사람이 설정하는 신호입니다. 로컬에서는 누구나 설정할 수 있습니다. CI에서는 라벨에서 오며, 라벨을 붙일 수 있는 사람은 관문을 풀 수 있습니다.
- 파일 패턴이 덮지 못하는 방식의 약화(예: `package.json` 안의 `test` 스크립트 수정)는 감지하지 못합니다. 필요하면 `FLAG_PATH_REGEX`에 그 파일을 추가하세요. 오탐이 늘어납니다.
- 테스트를 자주 고치는 팀은 `NEEDS_REVIEW`를 자주 보게 되고, 결국 무시하게 될 수 있습니다.
- 비밀값 제거는 환경변수 값(이름에 TOKEN, SECRET, KEY, PASSWORD, PASSWD, CREDENTIAL, COOKIE 포함, 6자 이상), Authorization/Cookie 헤더, Bearer 토큰만 다룹니다. 파일에 하드코딩된 값, 환경변수가 아닌 비밀값, 스크린샷은 볼 수 없습니다.
- `CHECK_TIMEOUT`은 `timeout` 또는 `gtimeout`이 필요합니다. macOS에는 기본으로 없으므로(coreutils 설치) 없으면 실행이 `BLOCKED`가 됩니다.
- `SKILL.md`의 Tier B(실제 앱 구동)와 Tier C(독립 리뷰)는 지침입니다. 스크립트가 강제하는 것은 `checks.txt`에 선언된 검사뿐입니다.
- 이 조합이 출처 하나만 쓰는 것보다 낫다는 측정 결과는 없습니다.
- Windows는 시험하지 않았습니다(WSL이나 Git Bash는 각자 책임으로).

## 여기서 검증한 것

`BASH_BIN=/bin/bash bash tests/run.sh`를 직접 실행해 보세요. bash 버전과 개수가 출력됩니다.

| 항목 | 상태 |
|---|---|
| macOS 시스템 bash 3.2.57에서 시나리오 테스트(verify.sh, plant.sh, install.sh, build) | 실행함, 결과는 CHANGELOG 참고 |
| Linux / 더 새로운 bash에서 같은 테스트 | 로컬에서는 실행 안 함. 저장소를 GitHub에 올린 뒤 CI가 실행 |
| 실제 `timeout` 바이너리 | 실행 안 함(종료 코드 124를 내는 대체 스크립트 사용) |
| shellcheck | 로컬 실행 안 함(미설치). CI job이 실행 |
| `agentskills validate` | 실행 안 함 |
| GitHub Actions 워크플로(이 저장소의 CI와 심어지는 워크플로) | 아직 실행 안 함 |
| 각 에이전트 도구에서 스킬 로딩 | 시험 안 함 |

## 출처와 라이선스

이 스킬이 가져온 아이디어와 각각의 확인 방법은 `skills/portable-verification/SOURCES.md`를 보세요. 그 파일은 자체 주장 중 여기서 검증하지 않은 것도 밝히고 있습니다. MIT 라이선스이며 `LICENSE`를 보세요. 재배포 전에 그 파일에 적힌 출처들의 라이선스를 확인하세요.
