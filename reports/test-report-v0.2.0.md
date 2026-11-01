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
