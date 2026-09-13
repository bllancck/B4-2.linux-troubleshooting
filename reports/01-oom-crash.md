# [OOM] MemoryWorker 메모리 증가와 MemoryGuard 종료

## 1. Description (현상 설명)

`agent-leak-app`을 기본 `MEMORY_LIMIT=256`으로 실행하면 `MemoryWorker`가 사용하는 Heap과 프로세스 RSS가 계속 증가한다. 실행 약 35초 후 내부 메모리 사용량이 275MB에 도달하면서 `MemoryGuard`가 제한 초과를 감지하고 프로세스를 종료한다.

재현 설정은 다음과 같다.

```text
MEMORY_LIMIT=256
CPU_MAX_OCCUPY=80
MULTI_THREAD_ENABLE=true
```

이 현상은 Linux 전체 메모리가 고갈되어 발생한 커널 OOM 종료가 아니라, 애플리케이션 내부 보호 기능에 의한 자기 종료다.

## 2. Evidence & Logs (증거 자료)

Before 설정은 [settings.txt](../evidence/oom/before-20260913-194113-782307006/settings.txt), 전체 실행 결과는 [run-summary.txt](../evidence/oom/before-20260913-194113-782307006/run-summary.txt)에서 확인할 수 있다.

시간별 관제 자료인 [metrics.tsv](../evidence/oom/before-20260913-194113-782307006/metrics.tsv)에서는 RSS가 다음처럼 증가했다.

```text
초기 RSS:    18,048KiB
최대 RSS:   274,048KiB
마지막 상태: PROCESS_EXITED
```

[전체 애플리케이션 로그](../evidence/oom/before-20260913-194113-782307006/application-full.log)에는 Heap이 25MB 단위로 증가하다 제한을 넘는 과정이 기록되어 있다.

```text
[MemoryWorker] Current Heap: 225MB
[MemoryWorker] Current Heap: 250MB
[MemoryWorker] Current Heap: 275MB
[MemoryGuard] Memory limit exceeded (275MB >= 256MB)
[MemoryGuard] Self-terminating process ... to prevent system instability.
```

프로세스 종료 코드는 137이었다. 애플리케이션이 로그로 자기 종료를 선언한 직후 프로세스가 사라졌다는 점은 단순 부팅 실패와도 구분된다.

추가 자료:

- [수집 시작 프로세스 상태](../evidence/oom/before-20260913-194113-782307006/process-initial.txt)
- [수집 시작 top 출력](../evidence/oom/before-20260913-194113-782307006/top-initial.txt)
- [분석 요약](../evidence/oom/analysis-summary.md)

## 3. Root Cause Analysis (원인 분석)

`MemoryWorker`는 실행 중 Heap을 반복해서 늘리며 이전에 확보한 메모리를 반환하지 않는다. 이에 따라 운영체제가 관찰한 RSS도 18,048KiB에서 274,048KiB까지 증가했다.

내부 사용량이 `MEMORY_LIMIT=256`을 넘자 `MemoryGuard`가 시스템 불안정을 막기 위해 프로세스를 의도적으로 종료했다. 따라서 직접적인 종료 원인은 Linux OOM Killer가 아니라 애플리케이션의 메모리 보호 정책이다. 그 정책을 작동시킨 원인은 실행 중 해제되지 않고 누적된 메모리다.

제공된 바이너리 내부 코드는 수정할 수 없으므로 메모리 할당과 해제 로직을 고치는 근본 해결은 이번 과제 범위에 포함되지 않는다.

## 4. Workaround & Verification (조치 및 검증)

우회 설정으로 `MEMORY_LIMIT`만 허용 범위의 512MB로 높였다.

```text
Before: MEMORY_LIMIT=256
After:  MEMORY_LIMIT=512
```

After 설정은 [settings.txt](../evidence/oom/after-20260913-195102-393699520/settings.txt), 판정 결과는 [run-summary.txt](../evidence/oom/after-20260913-195102-393699520/run-summary.txt)에서 확인할 수 있다.

변경 후 결과는 다음과 같다.

```text
RSS:                    18,048KiB로 유지
MemoryWorker 로그:      없음
Memory limit exceeded:  없음
oom_observed:            false
```

[After 전체 로그](../evidence/oom/after-20260913-195102-393699520/application-full.log)에서 512MB 설정은 `[OK]`로 판정됐다. 메모리 장애 대신 다음 우선순위의 CPU 보호 기능이 실행됐으므로 전체 프로그램이 안정화된 것은 아니지만, 해당 실행에서 OOM Crash는 재현되지 않았다.

자동 검증은 다음 명령으로 다시 수행할 수 있다.

```bash
./scripts/verify_oom_evidence.sh \
  evidence/oom/before-20260913-194113-782307006 \
  evidence/oom/after-20260913-195102-393699520
```
