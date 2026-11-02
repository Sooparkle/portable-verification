# 테스트 보고서: portable-verification + portable-eval v0.2.0 (미릴리스)

- 작성일: 2026-11-01
- 대상: `main` 로컬 커밋 `d66da82` (아직 push·릴리스하지 않음)
- 범위: portable-eval(실험적, 0.x) 신규 스킬과, 그에 따른 portable-verification·설치기·빌드 도구 변경
- 이 보고서는 외부 리뷰(Codex)용입니다. 맨 아래 "리뷰어에게 묻는 것"에 검토를 원하는 쟁점을 모았습니다.

## 1. 요약

| 항목 | 결과 |
|---|---|
| 전체 테스트 (macOS, 환경 3종) | 5회 실행, 실패 0건. 환경 A·B 345개 통과, 환경 C 344개 통과(교차 검증 1개 건너뜀). 커밋 d66da82에서 최종 1회 재실행: 345 ok, 0 not ok (Python 3.9.6 + jsonschema 4.25.1, 작업 트리에 보고서 외 변경 없음) |
| 같은 환경 반복 실행 (flaky 확인) | 환경 A를 3회 실행(1회는 시뮬레이션 부하와 동시에), 3회 모두 345/345. 불안정 테스트 0건 |
| 적대적 매트릭스 A1–A14 (계약 문서 8절) | 14개 항목 모두 고정된 기대값과 일치. **단, 매트릭스에 없는 공격(실행 중 ref 사본 변조)으로 trusted PASS가 가능함이 외부 리뷰에서 드러남(13절)**. A1c는 설계상 local PASS가 나옴 |
| 변이 검사 (규칙을 일부러 망가뜨리면 테스트가 실패하는가) | 최종 코드에서 19개 일괄 재실행, 19개 모두 검출. 개발 중 처음에는 1개(설치기 사전 점검 생략)가 검출되지 않아 테스트를 추가함 |
| 게이트 규칙 시뮬레이션 (실제 스케줄링·판정 함수 사용) | 설계 문서 확률과 일치 (200만 회, |z| ≤ 1.01; 8절) |
| 사용자 흐름 e2e (설치 → 채우기 → verify → 브랜치에서 회귀·채점기 변조 → trusted 게이트) | 8개 판정 모두 기대값과 일치 (`reports/e2e-walkthrough.sh`, 저장소 안에서도 실행해 8/8) |
| shellcheck 0.11.0 (`--severity=warning`) | 경고 0건 |
| 이번 테스트 라운드에서 찾아 고친 결함 | 4건 (아래 6절) |

> **2차 리뷰 (커밋 e2159ad 대상, 15절):** Codex 판정은 다시 "수정 후 릴리스"입니다. B1(trusted PASS 위조)은 부분 해소에 그쳤고, 이번 수정이 회귀 3건을 만들었습니다. 현재 커밋은 릴리스 대상이 아닙니다.

> **정정 (외부 리뷰 후):** 아래 결론은 철회합니다. Codex 리뷰에서 trusted 실행 중 어댑터가 추출된 ref 채점기를 바꿔 **trusted PASS를 얻는 경로**가 지적됐고, 재현됐습니다(13절). "어떤 공격도 PASS를 얻지 못함", "7개 불변조건이 보장", "설치의 원자성"은 과장이었습니다.

~~결론: 로컬 macOS 기준으로는 계약 문서의 약속이 테스트로 지켜집니다.~~ (철회) 그러나 GitHub Actions(Linux, CI 템플릿), 실제 LLM 에이전트, 저장소 보호 설정은 한 번도 실행하지 않았습니다(7절). 이 상태로는 "초기 구현"이며, 공식 평가 게이트로 쓸 수 있다는 근거는 아직 없습니다.

## 2. 환경

| | 값 |
|---|---|
| OS | macOS (Darwin 25.5.0, arm64) |
| bash | 3.2.57 (`/bin/bash`, macOS 기본). 이보다 새 bash는 이 기기에 없음 |
| Python | 시스템 3.9.6 (`/usr/bin/python3`), 3.13.1 |
| jsonschema (교차 검증용, 선택) | 3.9용 4.25.1, 3.13용 4.26.0. scratchpad의 일회용 venv에만 설치 |
| shellcheck | 0.11.0 (`shellcheck-py`, 일회용 venv) |
| Linux / GNU tar / 실제 `timeout` | **없음.** CI에서만 실행 예정 |

## 3. 테스트 구성

| 시나리오 | 내용 |
|---|---|
| `tests/scenarios/verify.sh` | verify.sh의 상태 5종, 약화 우회, 파싱, 비밀값 제거, 표준입력, 중단, 시간 초과(대체 스크립트) |
| `tests/scenarios/plant.sh` | verification 심기: 생성·보존·`--force`·`--check`·거부 |
| `tests/scenarios/plant-eval.sh` | eval 심기: 생성·보존·`--force`·`--check`·python3 없음·자리표시자 때문에 BLOCKED |
| `tests/scenarios/install.sh` | 두 압축파일 결정적 빌드, 고정 해시, `--skill both`의 원자성(한쪽 실패 시 둘 다 미설치), 다운로드 실패, 변조, 읽기 전용 대상, git 없는 PATH |
| `tests/scenarios/consistency.sh` | README 영·한 코드 블록 동일, 버전 일치, 스킬 이름 = 폴더 이름, 실행 권한 |
| `tests/scenarios/eval.sh` → `tests/py/test_pe.py` | 골든 수치, 스키마 검증기(+`jsonschema` 교차 검증), 게이트, 계약·적대적 매트릭스, trusted 모드, compare, 시뮬레이션, 프로세스 정리, 어댑터 경로 |

## 4. 결과 (환경별)

| 시나리오 | A: Python 3.9.6 + jsonschema 4.25.1 | B: Python 3.13.1 + jsonschema 4.26.0 | C: Python 3.9.6, jsonschema 없음 | A 반복 2 | A 반복 3 |
|---|---|---|---|---|---|
| consistency | 16 | 16 | 16 | 16 | 16 |
| eval (Python unittest) | 86 | 86 | 85 (+1 skip) | 86 | 86 |
| install | 89 | 89 | 89 | 89 | 89 |
| plant-eval | 39 | 39 | 39 | 39 | 39 |
| plant | 59 | 59 | 59 | 59 | 59 |
| verify | 56 | 56 | 56 | 56 | 56 |
| **합계 (not ok)** | **345 (0)** | **345 (0)** | **344 (0)** | **345 (0)** | **345 (0)** |

모든 행은 bash 3.2.57로 실행했습니다. 이 5회는 커밋 d66da82 직전의 작업 트리에서 돌았고, 그 뒤 커밋까지 바뀐 것은 문서 두 곳(contracts.md, SKILL.md의 severity 설명)과 e2e 스크립트 사본뿐입니다. 그래서 커밋 그대로 한 번 더 실행했습니다: 345 ok, 0 not ok (Python 3.9.6 + jsonschema 4.25.1, 작업 트리에 보고서 외 변경 없음)

교차 검증: 작은 검증기와 `jsonschema`가 4개 스키마의 유효 문서와 자동 생성한 변이(필수 필드 삭제, `null`·숫자·문자열·배열·객체·불리언으로 교체, 여분 필드, enum 위반, 조건부 필드 누락, `oneOf` 불일치 등) **전부에서 같은 판정**을 냈습니다(불일치 0건).

## 5. 적대적 매트릭스 (계약 문서 8절 대응)

| # | 공격 | 기대 | 결과 | 테스트 |
|---|---|---|---|---|
| A1a | 작업 트리의 채점기를 known_bad만 알아보는 속임수 채점기로 교체, 실제 출력은 실패 (trusted) | FAIL(1) | FAIL(1), `assets_verified=false`, `graded_with_ref_copies=true` | `test_a1a_*` |
| A1b | 같은 교체, 실제 출력은 성공 (trusted) | NEEDS_REVIEW(2) | 2, 변경 파일명 표시 | `test_a1b_*` |
| A1c | known_bad만 알아보고 나머지는 통과시키는 속임수 채점기 (local) | 게이트는 `local (unofficial)` 표기, verify.sh NEEDS_REVIEW(2) | 게이트 0 + 표기 확인, verify.sh 2 | `test_a1c_*`, e2e 7단계 |
| A2 | `policy_coverage` 누락 | BLOCKED(3) | 3 (스키마 단계에서 `evidence_invalid`로 먼저 걸림) | `test_a2_*` |
| A3 | 필수 관측기 `inactive` | BLOCKED(3) | 3 (`policy_coverage_inactive`, 재시도 후) | `test_a3_*` |
| A4 | manifest 필드를 빈 문자열/`null`로, 또는 섹션 삭제 | compare BLOCKED(3) | 3 (게이트 쪽도 불완전한 system manifest면 3) | `test_a4_*`, `test_incomplete_system_manifest_*` |
| A5 | known_bad 증거 교체 / 삭제 | BLOCKED(3) | 3 / 3 | `test_a5_*` |
| A6 | 항상 pass 채점기. **같은 케이스의 다른 기준 뒤에 숨긴 경우 포함** | BLOCKED(3) | 3 / 3 (숨긴 경우는 이번 라운드에서 고침, 6절) | `test_a6_*` |
| A7 | 채점기 예외 / 무한 루프 / `graders/` 밖 경로 / 심볼릭 링크 탈출 | BLOCKED(3) | 모두 3 | `test_a7_*` |
| A8 | Evidence가 JSON 아님 / `_executor` 위조 / 6 MiB 초과, 어댑터 비정상 종료 | BLOCKED(3) | 모두 3 (재시도 후) | `test_a8_*`, `test_adapter_crash_*` |
| A9 | 결과 이후 `decision` 변경 / `fixed_at`을 실행 이후로 | compare BLOCKED(3) | 3 / 3 | `test_a9_*`, `test_decision_fixed_after_*` |
| A10 | blind 케이스를 `cases/`에 둠 | BLOCKED(3) | gate 3, validate 3 | `test_a10_*` |
| A11 | critical 케이스가 6회 중 1회 실패 | 회귀 PASS(flaky) / 안전 FAIL | 0 / 1, `all`에서는 시행 6회 공유 후 1 | `test_critical_regression_case_*`, `test_all_gate_*` |
| A12 | 실행 중인 `pe.py`가 ref의 `pe.py`와 다름 | BLOCKED(3) | 3 | `test_a12_*` |
| A13 | `--trusted-ref` 해석 불가 | BLOCKED(3) | 3 | `test_a13_*` |
| A14 | PR에서 케이스·spec만 변경 / 추적 안 되는 새 케이스 추가 | NEEDS_REVIEW(2) | 2 / 2 / 2 | `test_a14_*`, `test_spec_change_*` |

추가로 확인한 불변조건: 깨끗한 trusted PASS의 `result.json`에 7개 불변조건이 모두 `true`; 실패는 리뷰보다 우선(FAIL > NEEDS_REVIEW); `runs/`와 `system-manifest.json` 변경은 자산 변경으로 치지 않음; `.eval/` 안 심볼릭 링크는 BLOCKED; 어댑터에 비밀 환경변수와 케이스의 `expected`가 전달되지 않음.

## 6. 이번 테스트 라운드에서 찾아 고친 결함

| # | 결함 | 어떻게 드러났나 | 수정 | 고정한 테스트 |
|---|---|---|---|---|
| 1 | **어댑터 상대경로가 동작하지 않음.** 어댑터는 새 임시 디렉터리에서 실행되므로 README 예시(`adapters/run.py`)가 그대로는 실패(BLOCKED) | e2e 준비 중 재현 | 인수 중 존재하는 상대경로를 시작 디렉터리 기준 절대경로로 변환(실행 파일 이름은 `/`가 없으면 그대로 PATH 검색) | `TestAdapterPaths` 3개 |
| 2 | **`severity: "critical"` 라벨만으로는 안전 게이트에 선택되지 않음.** 선택 기준은 `risk_tiers.critical`의 기준뿐이라 조용히 빠짐 | e2e(안전 게이트가 NOT RUN) | 동작은 유지하고 `validate`·`gate`에 경고 출력 | `test_severity_label_alone_*` |
| 3 | **채점기 자기 테스트의 구멍.** "known_bad에서 기준 하나라도 fail"이면 통과였으므로, 기준이 둘인 케이스에서 항상 pass 채점기를 다른 기준 뒤에 숨길 수 있었음. 계약의 A6 주장이 기준 하나짜리 케이스에서만 성립 | 보고서용 대응표를 쓰다가 발견, 실패 테스트로 재현 | 사용되는 **모든 채점기가 적어도 하나의 known_bad에서 fail**해야 함(아니면 BLOCKED). 설계 문서와 다른 점으로 기록 | `test_a6_*hidden*`, `test_every_used_grader_*` |
| 4 | **테스트의 구멍: 설치기의 사전 점검(`--check`)을 지워도 테스트가 통과.** 잘못된 인자는 어느 plant.sh든 쓰기 전에 거부해서 구별이 안 됐음 | 변이 검사 | eval 쪽만 실패하는 상황(PATH에 git 없음)에서 verification도 설치되지 않는지 확인하는 테스트 추가(대조군 포함) | `install.sh` 시나리오 |

결함 3은 사용자에게 영향이 있습니다. 설계 문서는 capability·safety 케이스의 known_bad를 선택으로 두지만, 이제 **사용되는 채점기마다 known_bad가 최소 하나** 있어야 게이트가 실행됩니다.

## 7. 변이 검사 (최종 코드에서 일괄 재실행)

개발 중에도 시점마다 변이 검사를 했지만, 아래는 커밋 d66da82의 코드에서 19개를 한 번에 다시 돌린 결과입니다. 변이마다 적용 → 관련 테스트 실행 → 메모리의 원본으로 복원 → 파일 해시가 원래와 같은지 확인했습니다(`pe.py`, `install.sh`, `verify.sh` 모두 복원 확인).

| 변이 | 결과 | 선택한 테스트 중 실패 수 |
|---|---|---|
| safety gate never fails on a violation | caught | 4 of 40 selected tests failed |
| grader self-test skipped | caught | 4 of 4 selected tests failed |
| known_bad hash pin not checked | caught | 1 of 2 selected tests failed |
| trusted asset comparison ignored | caught | 5 of 12 selected tests failed |
| regression blocks on a single failure | caught | 3 of 3 selected tests failed |
| running pe.py not compared with the ref | caught | 1 of 1 selected tests failed |
| policy coverage not checked | caught | 1 of 2 selected tests failed |
| oneOf accepts several matches | caught | 1 of 5 selected tests failed |
| decision-after-the-fact check removed | caught | 1 of 9 selected tests failed |
| null/empty manifest fields tolerated | caught | 1 of 1 selected tests failed |
| unrunnable trial counted as pass | caught | 1 of 1 selected tests failed |
| stragglers of the process group not killed | caught | 1 of 3 selected tests failed |
| extra trials never scheduled | caught | 4 of 5 selected tests failed |
| relative adapter paths not resolved | caught | 1 of 3 selected tests failed |
| grader-level self-test coverage disabled | caught | 2 of 22 selected tests failed |
| verify.sh no longer flags .eval/ | caught | 1 of 1 selected tests failed |
| install.sh hash comparison off | caught | 5 of 89 selected tests failed |
| install.sh pre-flight --check skipped | caught | 1 of 89 selected tests failed |
| install.sh compares with the wrong skill's pin | caught | 22 of 89 selected tests failed |

19개 중 19개 검출. 개발 중 처음 돌렸을 때는 "install.sh 사전 점검 생략" 변이가 **검출되지 않았고**(6절 결함 4), 테스트를 보강한 뒤 검출됩니다.

## 8. 시뮬레이션 (실제 `schedule_regression` / `decide_*` 함수, 시드 고정)

회귀가 없을 때의 거짓 차단(케이스당 확률이 작아 표본 잡음이 큼):

| reliability | samples | seed | simulated per case | exact per case | z | scaled to 100 cases (sim / exact / document) |
|---|---|---|---|---|---|---|
| 0.99 | 2000000 | 101 | 0.11560% | 0.11713% | -0.63 | 10.9% / 11.1% / 11.1% |
| 0.995 | 2000000 | 102 | 0.02980% | 0.02964% | +0.13 | 2.9% / 2.9% / 2.9% |
| 0.999 | 2000000 | 103 | 0.00095% | 0.00120% | -1.01 | 0.1% / 0.1% / 0.1% |

처음에는 40만 회, 세 조건에 같은 시드로 측정했는데 시뮬레이션이 0.99에서 12.0%(정확한 값 11.1%), 0.995에서 3.6%(2.9%)로 높게 나왔습니다. z는 약 +2.1, +2.6으로 허용 범위였지만, 같은 시드라 오차가 같은 방향으로 겹쳤을 수 있었습니다. 그래서 위처럼 200만 회, 조건별 다른 시드로 다시 쟀고 |z| ≤ 1.01이었습니다. 테스트(`TestSimulation`)는 4σ 기준으로 판정합니다.

회귀가 있을 때의 차단 확률과 비용:

| condition | samples | simulated | exact (formula) | document |
|---|---|---|---|---|
| regression to success 0.5, per case | 200000 | 82.9% | 82.8% | 82.8% |
| regression to success 0.7, per case | 200000 | 50.7% | 50.6% | 50.6% |
| regression to success 0.8, per case | 200000 | 29.2% | 29.1% | 29.1% |
| mean trials per case at 5% failure | 200000 | 3.402 | 3.406 | |

이 시뮬레이션은 "판정 코드가 문서의 규칙대로 동작한다"는 증거이고, 문서의 확률 모델(케이스 독립, 시행당 성공률 일정)이 현실에 맞는다는 증거는 아닙니다.

## 9. e2e (사용자 흐름, 압축파일로 설치)

| 단계 | 기대 | 결과 |
|---|---|---|
| `install.sh --skill both --archive-dir` (해시 고정본) | 두 해시 ok, 두 스킬 설치 | ok |
| 템플릿 그대로 `validate` | BLOCKED(3) | 3 |
| spec·채점기·케이스 2개(회귀·안전)·known_bad·manifest 채운 뒤 `validate` | 0 | 0 |
| 커밋 전 `verify.sh` (checks.txt에 eval 게이트 두 줄) | NEEDS_REVIEW(2) | 2 |
| 커밋 후 `verify.sh` | PASS(0) | 0 |
| `main`에서 trusted 게이트 | PASS(0), `SAFETY_CLAIM: not demonstrated` | 0, 표시됨 |
| 브랜치에서 평가 대상 코드에 회귀 | verify.sh FAIL(1) | 1 |
| 같은 브랜치에서 채점기를 속임수로 교체 → `verify.sh` | 로컬 게이트는 속아서 통과, 그래도 verify.sh NEEDS_REVIEW(2) | 2, `flagged: .eval/graders/outcome_check.py` |
| 같은 상태에서 `--trusted-ref main` | 진짜 회귀를 FAIL(1) | 1 |

재현: `bash reports/e2e-walkthrough.sh` (임시 디렉터리에서 실행, 저장소를 바꾸지 않음). 같은 내용 중 속임수 채점기 부분은 `test_a1c_*`가 단위 테스트로도 고정합니다.

## 10. 실행하지 않은 것 / 한계

- **GitHub Actions 전부.** 이 저장소의 CI(Ubuntu·macOS × Python 3.9·3.13)와, 프로젝트에 심어지는 `ci-github-actions.yml`·`ci-eval-trusted.yml`은 아직 GitHub에서 돈 적이 없습니다. Linux, GNU tar, 실제 `timeout`, shellcheck 0.9.0(CI 버전)은 push 후에야 확인됩니다.
- **실제 LLM 에이전트.** 어댑터는 모두 가짜 스크립트입니다. 이 도구가 실제 에이전트 평가에서 쓸모 있는지는 검증되지 않았습니다.
- **저장소 보호 설정.** CODEOWNERS, 필수 리뷰, 필수 검사는 설정이라 테스트하지 않았습니다. trusted 모드의 공식성은 이 설정에 달려 있고, PR은 워크플로 파일 자체를 고칠 수 있습니다.
- **어댑터가 주장하는 것.** 환경 격리, 정책 관측기 상태는 어댑터의 주장이며 도구는 주장만 확인합니다. 프로세스 그룹을 벗어나는 자식(`setsid` 등)은 정리하지 못합니다.
- **인프라 분류의 오용.** 어댑터가 실패를 숨기려고 `env_init_failed`를 내면 재시도 후 BLOCKED가 됩니다. PASS를 얻을 수는 없지만, 게이트를 계속 BLOCKED로 묶어 둘 수는 있습니다.
- **시간에 민감한 테스트.** 어댑터 시간 제한(1~3초)을 쓰는 테스트가 있어, 매우 느린 CI 러너에서는 거짓 실패가 날 수 있습니다. 반복 실행에서는 발생하지 않았습니다.
- 구현하지 않음: 케이스 상태 전이(설계 3.1), blind 세트 운영, 루브릭, LLM judge, 비열등성·우월성·동등성 검정, 이식성 검사, YAML 입력, Windows, `agentskills validate`, 각 에이전트 도구에서의 스킬 로딩.
- 골든 테스트는 수식이 문서와 같다는 증거일 뿐, 문서의 초기값 12개가 맞다는 증거가 아닙니다.

## 11. 리뷰어에게 묻는 것

1. **trusted 모드의 신뢰 근거.** 실행 중인 `pe.py`와 ref의 `pe.py` 바이트 비교, 자산 내용 해시 비교, ref 사본으로 채점. 이 세 가지면 "PR이 판정에 영향을 줄 수 없다"고 말하기에 충분한가? 워크플로 파일 변경 위험에 대해 문서의 대응(CODEOWNERS + 필수 리뷰, `pull_request_target` 금지)보다 나은 최소 대안이 있는가?
2. **채점기 단위 자기 테스트(6절 결함 3의 수정).** 설계의 "케이스 단위, known_bad 선택"보다 엄격합니다. 이 엄격함이 소규모 팀에 과한가, 아니면 known_bad가 지정할 "실패해야 하는 기준" 필드를 두는 편이 나은가?
3. **회귀 게이트의 조기 종료.** 처음 3회 중 2회 실패면 추가 3회 없이 차단합니다(판정은 같고 비용만 줄어듦). 누적 추적용 시행 기록이 줄어드는 것이 문제인가?
4. **NOT RUN(4)과 verify.sh.** verify.sh는 0이 아닌 종료 코드를 모두 실패로 셉니다. 선택된 케이스가 없는 eval 게이트 줄은 FAIL로 보입니다. 이게 맞는가(빈 필수 검사는 실패), 아니면 구분해야 하는가?
5. **정책 증거.** `policy_coverage`는 어댑터의 주장입니다. 0.x에서 이 수준을 "정책 증거 확인"이라고 불러도 되는가?
6. **릴리스 순서.** 압축파일 해시를 install.sh에 고정 → 그 커밋에서 CI 통과 → 같은 커밋에 태그 → 로컬 압축파일 그대로 업로드 → `check-release.sh`로 사슬 검증. 이 순서에 빠진 고리가 있는가? (`check-release.sh`는 실제 v0.1.0 릴리스로 시험해 통과함)

## 12. 재현 방법

```bash
git clone https://github.com/Sooparkle/portable-verification.git && cd portable-verification
git checkout d66da82        # push 후
BASH_BIN=/bin/bash PYTHON_BIN=/usr/bin/python3 bash tests/run.sh
python3 -m venv /tmp/pe-venv && /tmp/pe-venv/bin/pip install jsonschema
BASH_BIN=/bin/bash PYTHON_BIN=/tmp/pe-venv/bin/python bash tests/run.sh   # 교차 검증 포함
bash build/check-release.sh v0.1.0 --rebuild                              # 릴리스 사슬 검사 (기존 릴리스)
```

## 13. 외부 리뷰(Codex) 결과와 재현

- 리뷰 원문: `reports/codex-review-v0.2.0.md` (codex-cli 0.166.0, 읽기 전용 샌드박스)
- **Codex 판정: release after fixes** (수정 후 릴리스). "trusted PASS가 제공하는 보장보다 문서가 더 강하다."
- 아래 "재현"은 Codex의 주장을 제가 임시 프로젝트에서 다시 실행해 확인한 결과입니다(저장소는 바꾸지 않음).

| # | 지적 (Codex 심각도) | 재현 | 결과 |
|---|---|---|---|
| B1 | trusted 실행 중 어댑터가 임시 폴더에 추출된 ref 채점기를 고쳐 trusted PASS 획득 (높음) | **재현됨** | 실제 출력은 실패(`ok=False`)인데 `STATUS: PASS`, exit 0, 7개 불변조건 모두 `true`. 어댑터는 `TMPDIR`을 받고 같은 사용자 권한이라 `pe-ref-*`를 찾아 쓸 수 있음. 같은 권한으로 `trials.jsonl`도 지울 수 있음 |
| B2 | compare가 두 번째 manifest의 `decision_fixed_at`을 보지 않음 (높음) | **재현됨** | `compare(A, B[fixed_at=2099])` → COMPARABLE(0), 순서를 바꾸면 BLOCKED(3). `decision_sha256`은 같아도 manifest의 시각 필드가 서로 달라짐 |
| B3 | BLOCKED여야 할 오류가 traceback·FAIL로 끝남 (중간) | **재현됨** (env null) / 코드로 확인 (나머지) | system manifest `"env": null` → `TypeError` traceback, exit 1. evidence 파일 쓰기 `OSError` 미변환, FAIL 상태에서 기록 실패 시 FAIL 유지(계약은 BLOCKED) |
| B4 | 대상에 `.eval`이 일반 파일이면 사전 점검 통과 후 반쪽 설치 (중간) | **재현됨** (사전 점검 통과까지) | eval `plant.sh --check` exit 0. 이후 verification만 설치되고 eval이 실패하는 흐름은 추론 |
| B5 | `evidence_schema_verified`가 실제 기록과 다르게 true (중간) | **재현됨** | `evidence_invalid` 시도 후 재시도 성공 → `true`. 계약 문구("every trial's evidence")와 다름. 시간 초과 시행에는 검증된 증거 자체가 없음 |
| B6 | check-release가 기대 CI 작업 목록·원격 태그 SHA·소스–배포물 일치를 강제하지 않음 (중간) | 코드로 확인 | 맞음. 현재 커밋의 install.sh 해시는 `UNSET`(릴리스 때 채움) |
| B7 | 검증기 의미 불완전 (중간) | **재현됨** 3/3 | `items:false` 무시, `1.0`을 정수로 인정하지 않음(JSON Schema와 다름), `NaN` 허용 |
| B8 | `eval.sh`가 unittest 프로세스 종료 코드를 보지 않음 (중간) | 코드로 확인 | 맞음. 출력 패턴만 셈 |
| B9 | 계약의 trial별 grader 해시·어댑터 해시가 `trials.jsonl`에 없음 (낮음) | 코드로 확인 | 맞음. `adapter_sha`는 계산만 하고 기록하지 않음 |

A절에서 받아들인 보고서 정정:
- A1a의 교체물은 "항상 pass"가 아니라 known_bad만 알아보는 속임수 채점기다(5절 표 수정).
- A1c는 설계상 local PASS를 낸다. "어떤 공격도 PASS를 얻지 못함"은 문자 그대로 틀렸다.
- A8의 크기 초과 테스트는 금지 필드(`pad`)도 함께 넣어서, 크기 제한만 따로 검증하지 못한다. 변이 목록에 "크기 제한 제거"가 없었다.
- A3의 `unknown` 관측기 상태는 테스트하지 않았다.
- 채점기 단위 자기 테스트는 안전 게이트만 돌릴 때도 normal 기준의 채점기까지 요구해, 불필요하게 BLOCKED가 될 수 있다.
- 7개 불변조건 테스트는 플래그 7개가 `true`인지 볼 뿐, 각 조건을 독립적으로 검증하지 않는다.
- 매트릭스·변이·시뮬레이션 실행 로그는 저장소에 없어 리뷰어가 재확인할 수 없었다(변이 실행기와 시뮬레이션 스크립트는 저장소 밖에 있음).

### 수정 방향 (제안, 미착수)

| 우선 | 항목 | 방향 |
|---|---|---|
| 1 | B1 | 평가 자산(채점기 포함)을 시작 시 메모리에 읽어 두고, 채점할 때마다 새 임시 디렉터리에 그 바이트로 다시 써서 실행. 시행 기록도 메모리에 모아 마지막에 쓰고 `result.json`에 해시를 남김. 같은 사용자 권한에서는 완전한 격리가 불가능하므로(`setsid`로 살아남은 프로세스 등), 공식 판정의 전제를 "SUT를 다른 사용자/컨테이너에서 실행"으로 문서에 명시 |
| 2 | B2, B3, B5 | 두 manifest 모두 검사, 모든 I/O·형식 오류를 BLOCKED로, 증거 불변조건을 "모든 시도"로 바꾸거나 계약 문구를 정확히 |
| 3 | B4, B7, B8 | 사전 점검에 경로 종류 검사, 검증기 수정(`items:false`, 정수값 실수, `NaN` 거부), `eval.sh`에서 종료 코드 확인 |
| 4 | B6, B9, 테스트 보강 | 기대 CI 작업 목록·원격 태그 확인, trial별 해시 기록, A8 크기 단독 테스트·A3 `unknown` 테스트·불변조건 개별 테스트, 변이 실행기와 시뮬레이션 스크립트를 저장소에 포함 |


## 14. 리뷰 반영 후 수정과 재검증

### 14.1 수정 (Codex 지적 대응)

| # | 지적 | 수정 | 고정한 테스트 |
|---|---|---|---|
| B1 | trusted 실행 중 ref 채점기 변조로 trusted PASS | 채점기는 시작 시 읽은 바이트로 매번 새 임시 디렉터리에서 실행. 채점에 쓰는 자산(trusted: ref 사본, local: 작업 트리)을 매 채점 전과 종료 시 재해시, 바뀌면 BLOCKED. 시행 기록·증거는 메모리에 모았다가 마지막에 쓰고 `result.json`에 해시 기록. 어댑터에 전용 `TMPDIR`. **격리가 아니라 탐지**임을 계약 1절·README에 명시(공식 판정에는 다른 OS 사용자/컨테이너 필요) | `TestRunIntegrity`: ref 채점기 변조, ref 스냅샷 심기, 작업 트리 채점기 변조 → 3(공격이 실제 일어났는지도 단언), 로드 후 파일 변경이 채점에 영향 없음, 실행 디렉터리 삭제 → 판정·기록 온전, 실행 디렉터리 쓰기 불가 → 3, 전용 TMPDIR |
| B2 | compare가 두 번째 manifest의 결정 시각을 무시 | 두 manifest 모두 검사 + `decision_fixed_at` 동등 비교 | `test_second_manifest_*`, `test_differing_decision_times_*` |
| B3 | traceback·FAIL로 끝나는 오류 | system manifest 하위 필드 타입 검사, gate·validate·compare 모두 예외는 BLOCKED, 기록 실패는 판정과 무관하게 BLOCKED | `test_null_env_*`(거부 사유까지 단언), `test_unexpected_error_*`, `test_a17_*` |
| B4 | 경로 종류 충돌로 반쪽 설치 | 두 `plant.sh`의 `--check`가 쓸 모든 경로의 종류·쓰기 가능 여부 검사 | install 시나리오 4종 충돌(둘 다 미설치 확인), plant·plant-eval 시나리오 |
| B5 | 증거 불변조건이 실제와 다름 | 어떤 시도에서든 잘못된 증거가 나왔으면 `false`(재시도로 회복해도). 계약 문구를 실제 정의로 수정 | `test_trusted_pass_is_refused_after_an_invalid_evidence_attempt` (trusted 3 / local 0) |
| B6 | 릴리스 검사 고리 누락 | 원격 태그 = 로컬 태그 커밋, 기대 CI 작업 전체 존재(목록은 ci.yml과 테스트로 동기화), 자산 내용 = 태그의 `skills/<skill>/`(파일·바이트·실행 비트)를 기본 검사로 | consistency 시나리오, 실제 v0.1.0으로 시험 (아래) |
| B7 | 검증기 의미 | 엄격한 JSON(NaN·Infinity 거부), `1.0`은 정수, 비유한수 거부, `items:false` 지원 | `test_items_false_*`, `test_nan_in_evidence_is_invalid`, 교차 검증에 정수값 실수 변이 추가 |
| B8 | unittest 종료 코드 미확인 | `eval.sh`가 종료 코드와 "Ran N tests" 대비 집계 수를 단언 | 시나리오 자체 |
| B9 | trial 메타데이터 누락 | `trials.jsonl`에 `adapter_sha256`, 기준별 `grader_sha256` | `test_pass` 확장 |
| A절 | 테스트 약점 | 크기 초과 테스트를 스키마상 유효한 큰 증거로 분리, `unknown` 관측기 테스트, 안전 게이트만 돌릴 때는 critical 채점기만 자기 테스트 대상, 아무것도 선택되지 않아도 severity 경고 | `test_a8_oversize_evidence`, `test_a3_observer_unknown`, `test_safety_only_run_*`, `test_severity_warning_also_*` |

이번 라운드에서 제가 만든 실수 2건도 테스트가 드러냈습니다.
- 공격용 가짜 어댑터의 `glob("**")`가 숨김 폴더 `.eval`로 내려가지 않아, 처음 작성한 A15 테스트에서는 **공격 자체가 일어나지 않았습니다**(결과가 FAIL로 나와 발견). 경로를 고치고, 어댑터가 변조한 파일 수를 기록해 테스트가 "공격이 실제로 일어났음"을 단언하게 했습니다.
- `check-release.sh`의 기대 작업 목록 구분자를 쉼표로 했는데 작업 이름(`test (ubuntu-latest, 3.9)`)에 쉼표가 있어 목록이 잘못 쪼개졌습니다. v0.1.0으로 시험하다 발견해 `;`로 바꿨습니다.

### 14.2 재검증 결과 (macOS, bash 3.2.57)

로그: `reports/logs/` (테스트 매트릭스, 변이, e2e, 시뮬레이션, shellcheck). 도구: `reports/tools/mutations.py`, `reports/tools/simulate_gate.py`, `reports/e2e-walkthrough.sh`.

| 항목 | 결과 |
|---|---|
| 전체 테스트, 환경 3종 + 반복 2회 (수정 직후) | 5회 모두 실패 0건. A·B·A반복2·A반복3 각 376개, C 375개(교차 검증 1개 건너뜀) |
| 살아남은 변이용 테스트 3개 추가 후 환경 A | **378개 통과, 실패 0건** (코드는 그대로, 테스트만 추가) |
| 변이 검사 29개 (최종 코드) | **28개 검출, 1개 생존** (아래) |
| e2e (`reports/e2e-walkthrough.sh`) | 8/8 |
| 시뮬레이션 200만 회 | 문서 확률과 일치, \|z\| ≤ 1.01 |
| shellcheck 0.11.0 | 경고 0건 |
| `check-release.sh v0.1.0` (당시 작업 이름 지정) | OK. v0.2.0 작업 목록으로 검사하면 없는 4개 작업을 정확히 지목하며 실패 |

변이 검사 경과:
- 첫 실행(29개)에서 3개가 살아남았습니다. "compare가 A의 결정 시각만 읽음"은 `decision_fixed_at` 동등 비교가 있는 한 어떤 입력으로도 구별되지 않는 **동치 변이**라 목록에서 뺐습니다. "`decision_fixed_at` 동등 비교 제거"와 "system manifest 타입 검사 제거"는 테스트 구멍이어서 테스트를 보강했고, 이제 검출됩니다.
- 대신 추가한 "compare의 일반 오류 처리 제거" 변이는 **살아남았습니다.** 이를 위해 넣은 테스트(`test_unexpected_error_is_blocked_not_a_traceback`)의 입력이 스키마 검증에서 정상적인 BLOCKED로 걸려, 일반 오류 처리 경로까지 가지 않기 때문입니다. 테스트가 검증하는 동작(BLOCKED, traceback 없음)은 맞지만, 그 경로를 따로 검증하지는 못합니다. 사용자 결정에 따라 이번에는 고치지 않았습니다.
- ~~재리뷰(Codex 2차)는 사용자 결정으로 하지 않았습니다.~~ 커밋 후 사용자 결정으로 Codex 2차 리뷰를 진행했습니다. 14.1의 수정 중 일부는 해소되지 않았다는 판정을 받았습니다(15절).

### 14.3 남은 한계 (해결하지 않음)

- **같은 사용자 권한의 한계.** 프로세스 그룹을 벗어나 살아남은 프로세스(`setsid` 등)는 재해시와 채점 사이를 노릴 수 있습니다. 공식 판정에는 평가 대상을 다른 OS 사용자나 컨테이너에서 실행해야 하며, 도구는 이를 확인하지 못합니다. 이번 결정(범위 축소)에 따라 trusted 모드는 **실험적이며, 위 전제 없이 공식 판정이라 부르지 않습니다.**
- GitHub Actions(이 저장소 CI, 심어지는 워크플로), Linux, 실제 LLM 에이전트, 저장소 보호 설정은 여전히 실행·시험하지 않았습니다.
- 릴리스 핀은 아직 `UNSET`입니다(릴리스 단계에서 채움). 현재 커밋은 그대로 배포 가능한 설치기가 아닙니다.

## 15. 2차 외부 리뷰(Codex) 결과와 재현

- 리뷰 원문: `reports/codex-review-r2-v0.2.0.md` (codex-cli 0.166.0, `codex exec --sandbox read-only --ephemeral`, 대상 커밋 `e2159ad`)
- **Codex 판정: 수정 후 릴리스.** "기존 공격과 오류 처리 상당수는 수정됐지만, B1의 trusted PASS 위조 가능성은 남아 있다."
- Codex의 실행 범위: 파일 쓰기 없는 테스트 15개(14 통과, jsonschema 교차 검증 1개 건너뜀)와 메모리 호출만 실행했습니다. 전체 테스트, 설치, 변이 검사, 파일 변조 공격은 다시 돌리지 않았습니다. 나머지 판단은 정적 분석입니다.
- 아래 "재현" 열은 제가 직접 확인한 결과입니다. 저장소는 바꾸지 않았습니다. B4는 임시 디렉터리 재현 명령이 권한 거부로 실행되지 않아 코드로만 확인했습니다.

### 15.1 1차 지적(B1~B9) 해소 여부

| # | Codex 판정 | 남은 문제 | 재현 |
|---|---|---|---|
| B1 | **부분 해소** | ref 채점기를 덮어쓰는 기존 공격은 막힘. 우회 경로가 남음(15.2) | 코드로 확인 |
| B2 | 해소 | — | Codex가 메모리 호출로 BLOCKED(3) 확인 |
| B3 | 해소 | 일반 오류 처리 경로를 따로 검증하는 테스트는 여전히 없음(14.2의 생존 변이) | Codex가 `RuntimeError` 주입으로 BLOCKED 확인 |
| B4 | **부분 해소** | `need_dir`이 쓰기 권한(`-w`)만 보고 탐색 권한(`-x`)은 보지 않음. 쓰기는 되지만 탐색은 안 되는 `.eval`이면 verification만 설치되고 eval 설치가 실패할 수 있음 | 코드로 확인 (`skills/portable-eval/scripts/plant.sh` `need_dir`) |
| B5 | 해소 | — | — |
| B6 | **부분 해소** | 태그는 `origin`에서, CI·릴리스는 `install.sh`의 `REPO`에서 조회하는데 둘이 같은지 확인하지 않음. 압축파일은 `skills/<skill>/` 아래만 비교. 잘못된 태그·배포물을 실제로 거부하는지 시험하는 테스트가 없음 | 코드로 확인 |
| B7 | **부분 해소** | `1e999`가 파싱 후 `inf`가 되어 자유 형식 필드에서 검증 통과 | **재현됨**: `final_state`나 `final_output`에 `1e999`를 넣은 완전한 증거가 검증 오류 0건. 타입이 지정된 `latency_ms`에서는 거부됨 |
| B8 | 해소 | 러너 자체에 실패를 주입하는 회귀 테스트는 없음 | — |
| B9 | 해소 (기록 누락 기준) | `adapter_sha256`은 어댑터 파일 내용이 아니라 **argv의 해시**임. 어댑터 코드 무결성의 증거로 읽으면 안 됨 | 코드로 확인 (`pe.py`의 `sha256_text(canonical(adapter_argv))`) |

### 15.2 B1에 남은 공격 경로 (Codex 정적 분석)

전제는 모두 어댑터가 `pe.py`와 같은 사용자 권한으로 실행된다는 것입니다.

| 경로 | 내용 |
|---|---|
| 실행용 임시 채점기 교체 | 저장한 바이트를 `pe-grader-*`에 쓴 뒤 Python이 그 경로를 다시 엽니다. 그 사이에 살아남은 프로세스가 파일을 바꿀 수 있습니다. 이 디렉터리는 재해시 대상이 아니고, 기록되는 해시는 원래 바이트의 해시입니다 |
| 스냅샷·케이스·증거 경쟁 | 증거는 검증하고 메모리에 저장한 뒤, 같은 경로의 파일을 채점기에 넘깁니다. 채점하는 순간에 내용을 바꿨다가 되돌리면, 검증·보존된 증거와 실제로 채점된 증거가 달라질 수 있습니다 |
| **Python 환경 변조** | 타이밍을 맞출 필요가 없습니다. 평가기의 site-packages에 어댑터가 쓸 수 있으면 `.pth` 또는 `sitecustomize`로 채점기 프로세스를 가로채 PASS를 낼 수 있습니다. `-I`는 site 로딩을 끄지 않습니다(Codex가 `isolated=1`, `no_site=0` 확인). 실제 위조까지 실행하지는 않았습니다 |
| 결과 쓰기 전후 변경 | 마지막 자산 검사가 `finish()` 전에 끝납니다. 기록 파일과 그 해시를 같은 공격자가 함께 고칠 수 있으므로, 해시는 독립적인 신뢰 근거가 아닙니다 |
| `pe.py` 자체 | 실행 중에 디스크의 `pe.py`를 바꿔도 이번 판정이 바로 바뀌지는 않습니다. 다만 시작할 때 한 번만 비교하므로 이후 변조를 탐지하지 않습니다 |

정리하면, "시작 시 읽은 바이트로 실행한다"는 개선은 맞지만 **그 바이트가 실제 채점 프로세스에서 실행됐다는 보장은 없습니다.** 같은 사용자 권한에서는 탐지일 뿐 격리가 아니라는 14.3절의 서술과 같은 결론이며, 위험 범위는 14.3절보다 넓습니다.

### 15.3 이번 수정(e2159ad)이 만든 회귀

| 심각도 | 내용 | 재현 |
|---|---|---|
| 중간 | **오류로 중단된 실행에서 이미 끝난 trial 기록이 사라짐.** 기록을 메모리에 모았다가 `finish()`에서 쓰게 바꿨는데, `cmd_gate`의 예외 경로는 `result.json`만 씁니다. 공격을 탐지해 BLOCKED로 끝난 실행일수록 감사 자료가 남지 않습니다 | 코드로 확인 (`cmd_gate`의 `except Exception` 블록) |
| 중간 | **manifest 해시를 비교 없이 기록.** 쓴 뒤 다시 읽은 내용을 의도한 내용과 비교하지 않고 그 해시를 그대로 씁니다. 또 계약 1절 7번은 `result.json`까지 다시 읽어 확인한다고 적었지만, 실제로는 다시 읽지 않습니다 | 코드로 확인 (`finish()`) |
| 낮음 | **`exec` 채점기의 실행 권한 요구가 사라짐.** `os.access(X_OK)` 검사를 지우고 사본에 `0700`을 줍니다. 계약 문서의 "must be executable"과 다릅니다 | 코드로 확인 (`git show e2159ad`에서 검사 삭제 확인) |

### 15.4 14절 주장과 로그 대조 (Codex)

| 주장 | 대조 결과 |
|---|---|
| 378 통과 | 로그와 일치(`17+105+97+42+61+56`). Python 테스트만이 아니라 shell 단언과 러너 검사를 합친 수입니다 |
| 환경 3종 + 반복 2회 | 376/376/375/376/376은 수정 직후 결과입니다. 최종 378은 환경 A에서만 돌린 결과이며, 최종 상태를 모든 환경에서 검증했다는 뜻이 아닙니다 |
| 변이 28/29 | 로그와 실행기 정의가 일치합니다. 생존 변이에 대한 설명도 정확합니다 |
| "공격이 일어났는지까지 확인" | **A15 세 테스트에만 해당합니다.** 다른 공격 테스트에는 같은 단언이 없습니다. 모든 공격 테스트로 일반화하면 과장입니다(14.1의 표현을 이 범위로 한정합니다) |
| e2e 8/8 | 일치. 마지막 local gate의 종료 코드는 출력만 하고 단언하지 않습니다 |
| `check-release.sh v0.1.0` OK | 실행 로그가 `reports/logs/`에 없어 독립 대조를 못 했습니다 |
| 로그와 커밋의 연결 | 로그의 출발점은 `20e5acf + 작업 트리 변경`이고 파일 해시가 없습니다. 로그가 `e2159ad`의 바이트를 그대로 실행했다는 증명은 되지 않습니다 |

### 15.5 14.3절(남은 한계)에 대한 평가

Codex는 "방향은 정확하지만 충분하지 않다"고 평가했습니다. 다음 내용을 보완해야 합니다.
1. 보호 대상은 ref 자산만이 아닙니다. Python 실행 파일·라이브러리·site-packages, 실행용 임시 파일, 증거·결과 저장소까지 포함해야 합니다. 타이밍을 맞출 필요가 없는 Python 환경 공격도 한계 목록에 넣어야 합니다.
2. "다른 사용자나 컨테이너"라고만 적으면 부족합니다. 평가기 쪽 파일과 결과를 평가 대상이 수정할 수 없는 권한·마운트 구성이 필요합니다.
3. **CI 템플릿이 공식 판정의 전제와 어긋납니다.** `skills/portable-eval/references/ci-eval-trusted.yml`은 스스로를 "Official eval gate"라고 소개하지만, 어댑터를 같은 러너 사용자로 실행합니다. `plant.sh`의 안내도 이 템플릿을 공식 경로로 소개합니다.
4. 계약의 기록 보존 문구(`result.json`을 다시 읽어 확인)를 실제 구현에 맞춰야 합니다.

### 15.6 수정 방향 (제안, 미착수)

| 우선 | 항목 | 방향 |
|---|---|---|
| 1 | CI 템플릿과 공식성 표시 | 템플릿을 "실험적, 같은 사용자 실행"으로 다시 표시하거나, 어댑터를 다른 사용자·컨테이너에서 실행하는 구성으로 바꿉니다. 계약·README·`plant.sh` 안내를 같은 표현으로 맞춥니다 |
| 2 | 15.3 회귀 | 예외 경로에서도 끝난 trial 기록과 증거를 씁니다. manifest는 다시 읽은 내용을 의도한 직렬화 결과와 비교하고, `result.json`도 다시 읽어 확인하거나 계약 문구를 고칩니다. `exec` 채점기의 원본 실행 권한 검사를 되살립니다 |
| 3 | B4, B7 | `need_dir`에 `-x` 검사를 추가합니다. 파싱 후 비유한수를 자유 형식 필드까지 포함해 거부합니다(`parse_float`에서 `inf` 거부) |
| 4 | B6 | `origin`과 `REPO`가 같은지 확인하고, 압축파일 전체 구성을 검사합니다. 잘못된 태그·배포물을 거부하는지 시험하는 테스트를 추가합니다 |
| 5 | 14.3 보완, 로그 | 15.5의 1~2를 한계 목록에 넣습니다. 최종 커밋에서 테스트를 다시 돌리고, 커밋 해시를 남긴 로그로 교체합니다 |
