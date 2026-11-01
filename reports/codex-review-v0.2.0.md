# Codex 리뷰 원문 (v0.2.0 테스트 보고서 대상)

- 도구: codex-cli 0.166.0, `codex exec --sandbox read-only --ephemeral` (파일 변경 불가)
- 대상 커밋: 9b1bf24 (보고서 대상 d66da82 + 보고서·CHANGELOG)
- 요청문: 보고서 주장 대조, 누락 결함, 11절 질문 답변, 최종 판정
- 아래는 Codex 출력 그대로이며, 절대경로만 저장소 상대경로로 바꿨습니다. 각 지적의 재현 여부는 `test-report-v0.2.0.md` 13절에 있습니다.

---

## A. 보고서 주장과 코드·테스트 대조

**현재 보고서의 “계약 문서의 약속이 테스트로 지켜진다”는 결론은 과합니다.** 정상 경로와 여러 공격 사례는 검증하지만, trusted PASS의 신뢰 경계와 불변조건에는 실제 구멍이 있습니다.

검토 대상 HEAD는 `9b1bf24`이며, 보고서 대상 `d66da82` 이후 차이는 보고서와 CHANGELOG뿐입니다. 파일은 수정하지 않았습니다. 읽기 전용 환경이라 전체 통합 테스트는 재실행하지 못했습니다. 파일 쓰기가 없는 테스트 19개를 실행해 **18개 통과, jsonschema 교차 검증 1개 건너뜀**을 확인했습니다. 아래에서 실행 재현과 정적 분석을 구분합니다.

### 적대적 매트릭스 A1–A14

라인은 `tests/py/test_pe.py` 기준입니다.

| 항목 | 기대 종료 코드 단언 여부 | 판단·제한 |
|---|---|---|
| A1a/b | 513–528: 각각 `1`, `2` 단언 | 확인. 다만 실제 교체물은 **항상 pass**가 아니라 known_bad만 알아보는 `GRADER_CHEAT`입니다. 보고서의 공격 설명과 다릅니다. |
| A1c | 530–550: verify `2`, local gate `0`, unofficial 표시 단언 | 확인. 따라서 요약의 “어떤 공격도 PASS를 얻지 못함”은 문자 그대로 틀립니다. |
| A2 | 329–334: `3`, `evidence_invalid` 단언 | 확인. 해당 테스트에서 재시도 횟수 자체는 단언하지 않습니다. |
| A3 | 336–341: `3`, coverage 오류 단언 | `inactive` 확인. 계약에 함께 적힌 `unknown`을 주입하는 테스트는 없습니다. |
| A4 | 645–656: 빈 문자열·null·섹션 삭제에 `3` | compare 확인. gate 테스트는 `system.model_id=""`만 다루며, 모든 불완전 manifest를 포괄하지 않습니다. B3 참조. |
| A5 | 343–357: 교체·삭제에 `3` | 확인. |
| A6 | 359–387: 단독·다른 기준 뒤에 숨긴 경우 `3`, coverage 보완 후 `0` | 확인. |
| A7 | 395–425: 예외·무한 대기·외부 경로·symlink에 `3` | 확인. |
| A8 | 427–446: 잘못된 JSON·`_executor`·대용량·crash에 `3` | 코드 단언은 있음. **대용량 fixture에는 금지된 `pad` 필드도 있으므로 크기 제한을 제거해도 이 테스트는 통과할 수 있습니다.** 크기 제한만 검증하는 테스트가 아닙니다. |
| A9 | 658–671: decision 변경·미래 시각에 `3` | 확인하지만 미래 시각 테스트는 같은 manifest를 양쪽에 전달합니다. 두 번째 manifest만 잘못된 경우를 놓칩니다. B2 참조. |
| A10 | 448–454: gate·validate 모두 `3` | 확인. |
| A11 | 297–315: regression `0`, safety `1`, all `1` | 확인. standalone safety는 기본 3회이며 실패가 세 번째에 있습니다. **6회 공유**는 `all` 테스트가 별도로 단언합니다. |
| A12 | 552–558: `3` | 확인. 파일에 주석을 추가하는 테스트입니다. 검증 코드를 제거한 악성 `pe.py`까지 방어한다는 증거는 아닙니다. |
| A13 | 560–564: `3` | 확인. |
| A14 | 566–584: 케이스 변경·추가·spec 변경에 `2` | 확인. |

### trusted PASS의 7개 불변조건

`test_clean_trusted_pass_has_all_seven_invariants`는 **불리언 7개가 모두 true인지** 확인합니다. 각 조건이 실제로 성립하는지를 독립 검증하는 테스트는 아닙니다.

| 불변조건 | 확인 결과 |
|---|---|
| `ref_pinned` | SHA 해석과 실행 파일 바이트 비교 구현 확인. ref가 신뢰할 만한 기준인지 지정하는 책임은 호출자에게 있습니다. |
| `assets_verified` | 실행 **전** 내용 비교만 확인. 실행 중 변경을 잡지 않습니다. |
| `evidence_schema_verified` | 마지막 재시도 결과만 반영합니다. 앞선 잘못된 증거를 누락하며, timeout에는 검증된 Evidence가 없어도 true가 유지됩니다. |
| `selftest_passed` | 선택된 케이스에 대한 grader 단위 coverage 검사 구현과 테스트 확인. |
| `graded_with_ref_copies` | ref 추출 직후 true로 설정합니다. 이후 그 사본이 변경되지 않았다는 보장은 없습니다. |
| `gate_executed` | 선택·스케줄링·판정 경로 확인. 빈 선택은 `4`입니다. |
| `artifacts_preserved` | 정상 쓰기 경로는 있지만 파일 존속·내용을 최종 검증하지 않습니다. 쓰기 실패 처리도 계약과 다릅니다. |

### grader 단위 자기 테스트와 설치 사전 점검

- **grader 단위 coverage 수정은 실제로 구현되어 있습니다.** `selftest()`는 사용된 grader 집합과 known_bad에서 fail한 grader 집합을 비교합니다. 두 grader 중 하나가 다른 하나 뒤에 숨는 테스트도 있습니다.
- 다만 coverage 범위는 **선택된 케이스들**입니다. 다른 게이트에만 선택되는 케이스의 known_bad는 coverage에 기여하지 않습니다. 또한 safety 실행에서도 선택된 케이스의 **모든 criteria**를 self-test하므로, 실제 safety 채점에서 제외되는 normal grader 때문에 BLOCKED가 될 수 있습니다.
- `install.sh:107`은 모든 스킬에 `--check`를 실행한 뒤 설치합니다. `tests/scenarios/install.sh:169`의 git 없는 PATH 대조군은 이 순서를 실제로 구별합니다.
- 그러나 보고서의 **“원자성, 한쪽 실패 시 둘 다 미설치”**는 과장입니다. 사전 점검 실패에는 맞지만 설치 도중 실패에는 맞지 않습니다. 설치기 자체도 비트랜잭션임을 명시합니다. B4의 사전 예측 가능한 실패까지 놓칩니다.

### 그 밖의 확인 불가·과장

- 5회 전체 실행, 부하 중 반복 실행, shellcheck 결과, 변이 19개 검출은 이번 환경에서 독립 재확인하지 못했습니다. 저장소에서 해당 실행 로그와 변이 실행기를 찾지 못했습니다.
- 보고서의 200만 회·seed 101–103 시뮬레이션과 달리 저장된 테스트는 40만 회·다른 seed를 사용합니다. 저장된 시뮬레이션 테스트는 통과했지만 **보고서 표의 실측값 자체는 재확인하지 않았습니다.**
- JSON Schema 교차 검증은 제한된 변이 집합입니다. `items:false`, 정수값 실수 `1.0`, 비표준 JSON 숫자는 포함하지 않습니다. B7 참조.
- e2e에는 8개 `expect`가 있습니다. 설치 명령의 성공과 마지막 local gate의 `0`은 별도 단언하지 않고, 일부 출력도 표시만 합니다. “8개 판정”은 맞지만 표 전체를 각각 검증한다는 뜻은 아닙니다.
- severity 경고는 빈 safety 선택에서 출력되지 않습니다. `finish()`에 `assets`가 전달되지 않기 때문입니다. 해당 테스트도 경고는 `validate`에서만 확인합니다.

## B. 보고서가 놓친 결함

### 1. 높음 — 실행 중 ref 채점기를 바꿔 trusted PASS를 얻을 수 있음

위치: [pe.py:938](skills/portable-eval/scripts/pe.py:938), `979`, `562–579`.

ref 사본은 같은 사용자 소유의 임시 디렉터리에 쓰기 가능한 상태로 추출됩니다. self-test 이후 어댑터를 같은 사용자 권한으로 실행하고, 채점 시 그 파일을 다시 실행합니다.

구체적인 실패 시나리오:

1. 작업 트리와 ref는 동일하여 `assets_verified=true`.
2. 원래 grader가 self-test를 통과.
3. 어댑터가 임시 루트의 `pe-ref-*`를 찾아 추출된 grader를 `sys.exit(0)`으로 교체.
4. 실제로 실패한 Evidence를 출력.
5. 변경된 grader가 pass를 반환. 실행 후 해시는 기록하지만 원래 해시와 비교하지 않음.
6. **7개 플래그가 true인 trusted PASS가 가능.**

같은 권한으로 앞선 `trials.jsonl`과 evidence를 삭제해도 마지막 쓰기가 성공하면 `artifacts_preserved=true`가 될 수 있습니다.

이는 정적 분석으로 확인한 경로이며 공격 e2e는 실행하지 못했습니다. 보고서가 파일 격리 부재를 언급하지만, 그것이 **trusted 판정 자체를 위조할 수 있음**까지 설명하지는 않습니다. 단순 chmod는 같은 소유자의 공격을 막지 못합니다.

### 2. 높음 — compare가 두 번째 manifest의 사후 decision 시각을 무시

위치: [pe.py:1160](skills/portable-eval/scripts/pe.py:1160).

`fixed`를 A에서만 읽고 두 실행 시각과 비교합니다. B의 `decision_fixed_at`은 동등성 비교 대상에도 없습니다.

정상 A를 복사한 B에서 `decision_fixed_at`만 `2099-01-01`로 변경하면:

```text
compare(A, B) → STATUS: COMPARABLE, exit 0
```

**메모리 기반 호출로 재현했습니다.** B의 시각도 검사하고 두 manifest의 decision 메타데이터 일관성을 검증해야 합니다.

### 3. 중간 — BLOCKED여야 할 오류가 FAIL 또는 traceback으로 끝남

위치: [pe.py:856](skills/portable-eval/scripts/pe.py:856), `788`, `1010`, `1073`.

- system manifest가 `"env": null`이면 스키마 검증 전에 `dict(None)`에서 `TypeError`. `cmd_gate`는 `Blocked`만 잡으므로 CLI는 traceback과 일반 종료 코드 `1`로 끝납니다.
- evidence 파일 쓰기는 `OSError`를 `Blocked`로 변환하지 않습니다. 디스크 부족·권한 오류도 같은 문제가 생깁니다.
- 이미 판정이 FAIL일 때 manifest/result 쓰기가 실패하면 `finish()`는 **FAIL(1)을 유지**합니다. 계약의 `BLOCKED > FAIL` 및 “write failure is BLOCKED”와 다릅니다.

null env의 `TypeError`와 FAIL+쓰기 실패의 `1` 유지 모두 메모리 호출로 확인했습니다.

### 4. 중간 — 사전 점검이 놓치는 기존 경로 충돌 때문에 반쪽 설치

위치: [eval plant.sh:35](skills/portable-eval/scripts/plant.sh:35), `67`, `install.sh:107–110`.

대상 루트가 쓰기 가능하고 그 아래 `.eval`이 **디렉터리가 아닌 일반 파일**인 경우:

1. 두 스킬의 `--check`가 성공합니다.
2. verification 설치가 완료됩니다.
3. eval 설치가 `.eval/cases` 등을 만들다가 실패합니다.
4. verification과 일부 eval 스킬 파일이 남습니다.

디스크 부족 같은 사후 오류가 아니라 **사전 점검 시 이미 알 수 있는 충돌**입니다. 스킬 목적지, `.eval`, workflow 경로의 종류·쓰기 가능성까지 검사하거나 원자성 주장을 좁혀야 합니다.

### 5. 중간 — 증거 불변조건이 실제 기록과 다르게 true

위치: [pe.py:805](skills/portable-eval/scripts/pe.py:805).

`evidence_invalid → 정상 성공` 순서의 재시도에서 슬롯은 pass이고 `evidence_all_valid=True`입니다. **메모리 호출로 재현했습니다.**

또한 regression에서 adapter timeout이 한 번, 나머지 다섯 번 성공이면 flaky PASS가 가능합니다. timeout 시행에는 검증된 Evidence 자체가 없지만 불변조건은 true입니다.

재시도 복구를 허용하는 정책은 합리적일 수 있습니다. 그러나 현재의 **“every trial’s evidence passed”**라는 계약과는 다릅니다. 모든 attempt를 집계하거나 조건을 “채점에 사용한 정상 Evidence”로 정확히 재정의해야 합니다.

### 6. 중간 — 릴리스 검사기가 소스–CI–배포물 연결을 완전히 검증하지 않음

위치: [check-release.sh:39](build/check-release.sh:39), `62`, `81`.

- **CI 작업 목록 미검증:** 발견된 check가 하나이고 그것만 성공해도 통과합니다. 예상한 OS×Python 4개와 lint가 모두 존재하는지 확인하지 않습니다.
- **원격 태그 SHA 미검증:** 로컬 태그의 커밋을 검사하고 원격 릴리스는 태그 이름으로 다운로드합니다. 두 태그가 같은 커밋을 가리키는지 확인하지 않습니다.
- **배포물–소스 일치가 선택 사항:** 기본 실행은 핀과 다운로드 바이트만 비교합니다. `--rebuild`도 다른 바이트를 경고로 끝냅니다. 잘못된 소스에서 만든 아카이브를 핀으로 고정해도 기본 검사는 통과할 수 있습니다.
- 현재 `install.sh:24–25`는 두 핀이 `UNSET`입니다. 설치 테스트는 이를 임시 사본에서 치환하므로 **현재 커밋 자체가 배포 가능한 설치기라는 증거는 아닙니다.**

동일 빌드 환경에서 `--require-identical`을 필수로 하거나, 압축 형식 차이를 허용하려면 추출 내용·권한을 태그 소스와 비교해야 합니다.

### 7. 중간 — 자체 JSON Schema 검증기의 지원 의미가 불완전

위치: [pe.py:153](skills/portable-eval/scripts/pe.py:153), `199`, `207`, `779`.

파일 쓰기 없이 다음을 확인했습니다.

| 입력 | 현재 결과 | 문제 |
|---|---|---|
| `[1]`, schema `{"items":false}` | 유효 | boolean `items`를 무시 |
| `1.0`, schema `{"type":"integer"}` | 무효 | JSON Schema의 정수값 숫자 의미와 불일치 |
| `NaN`, schema `{"type":"number","minimum":0}` | 유효 | Python JSON parser가 비표준 숫자를 허용하고 범위 비교도 통과 |

예를 들어 정상 Evidence에 `"cost": NaN`을 추가해도 검증을 통과할 수 있습니다. grader가 cost를 보지 않으면 PASS를 막지 않습니다. 배포된 스키마는 현재 `items:false`를 사용하지 않지만, 계약상 지원 범위에는 포함됩니다.

### 8. 중간 — Python 테스트 프로세스 실패가 테스트 러너에서 사라질 수 있음

위치: [tests/scenarios/eval.sh:18](tests/scenarios/eval.sh:18).

unittest 프로세스 종료 코드를 저장하지 않고 출력의 `... ok/FAIL/ERROR`만 집계합니다.

앞의 몇 테스트가 성공한 후 프로세스가 강제 종료되거나 `setUpClass` 오류처럼 해당 패턴과 다른 오류가 발생하면, 일부 `ok`만 집계하여 시나리오가 성공할 수 있습니다. 이는 실제 보고서 실행이 실패했다는 뜻은 아니지만, **“실패 0” 집계의 신뢰성 결함**입니다.

### 9. 낮음 — 계약에 약속한 trial 메타데이터가 없음

위치: [pe.py:754](skills/portable-eval/scripts/pe.py:754), `807`, `972`.

`adapter_sha`는 계산하지만 기록하지 않습니다. `grader_hashes`도 run 단위로만 누적하여 manifest에 쓰고, 각 `trials.jsonl` 레코드에는 없습니다.

따라서 계약의 “trial별 grader hashes”와 “executor adapter hash”는 구현되지 않았습니다. 특히 실행 중 grader가 달라지면 현재 manifest는 마지막 해시만 남깁니다.

**호환성:** 이번 검토에서 bash 3.2/Python 3.9에만 해당하는 확정적인 언어·API 비호환은 찾지 못했습니다. Python 3.9 문법 테스트는 통과했지만 실제 Python 3.9 전체 실행과 Linux 동작은 이번에 검증하지 못했습니다.

## C. 보고서 11절의 여섯 질문

1. **trusted 근거 세 가지로 충분한가?**  
   아닙니다. 실행 중 사본 변경과 기록 변조를 막지 못합니다. 최소한 평가기는 SUT가 쓰거나 제어할 수 없는 별도 권한·실행 환경에 두어야 합니다. workflow 신뢰도 PR이 수정 가능한 workflow와 별도로 고정해야 합니다. CODEOWNERS는 리뷰 절차이지 실행 격리는 아닙니다.

2. **grader 단위 자기 테스트가 과한가?**  
   실험적 게이트의 최소 조건으로 적절합니다. `known_bad`에 실패해야 할 criterion 목록을 두면 더 명확합니다. 예상한 기준이 실패했는지 검사하면서 grader coverage도 유지하는 편이 낫습니다. 단, 현재 검사도 known_bad 암기형 grader를 증명하지는 못합니다.

3. **회귀 조기 종료가 문제인가?**  
   게이트 판정에는 문제없습니다. 다만 시행 수가 결과에 따라 달라지므로 그 기록을 단순 성공률 추정에 재사용하면 편향될 수 있습니다. 고정 횟수 측정과 게이트 기록을 구분하면 됩니다.

4. **NOT RUN을 verify FAIL로 보는가?**  
   필수 검사라면 비영 종료로 차단하는 것이 맞습니다. 다만 “SUT 실패”와 “선택된 검사 없음”은 표시상 구분하는 편이 정확합니다. 선택적 검사라면 `required=no`를 사용하면 됩니다.

5. **“정책 증거 확인”이라고 불러도 되는가?**  
   **“어댑터가 제출한 정책 증거의 형식·coverage 주장 확인”**이라면 가능합니다. 정책 준수나 관측기의 실제 작동을 확인했다고 표현하면 과장입니다.

6. **릴리스 순서에서 빠진 고리인가?**  
   원격 태그와 CI 커밋의 동일성, 예상 CI 작업 전체의 존재, 태그 소스와 업로드 아카이브의 일치가 빠져 있습니다. 현재 검사기는 이 세 가지를 강제하지 않습니다.

## D. 최종 판정

**release after fixes**

릴리스 전 필수 수정은 다음과 같습니다.

- trusted 실행 중 채점기·기록 변조 경로를 차단하거나, 공식 trusted 보장 범위를 명시적으로 축소.
- compare의 두 번째 `decision_fixed_at` 검사.
- 잘못된 manifest와 I/O 오류를 일관되게 BLOCKED 처리.
- 증거·artifact 불변조건을 실제 보장과 일치시키고 실패 경로 테스트 추가.
- 설치 pre-flight의 기존 경로 충돌 검사와 원자성 표현 수정.
- 스키마 검증기와 unittest 종료 코드 집계 수정.
- 릴리스 핀 설정, 예상 CI 전체 통과, 원격 태그·소스·배포물 연결 검증.
- 보고서의 공격 무조건 차단, 7개 불변조건 보장, 설치 원자성 표현 수정.

실험적이라는 표시는 적절하지만, 현재의 **trusted PASS가 제공하는 보장보다 문서가 더 강합니다.**