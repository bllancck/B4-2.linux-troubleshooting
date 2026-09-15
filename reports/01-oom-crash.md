# [Bug] OOM - 메모리 증가와 MemoryGuard 종료

## 1. Description (현상 설명)

다른 장애가 섞이지 않도록 `CPU_MAX_OCCUPY=40`, `MULTI_THREAD_ENABLE=false`로 고정했습니다. `MEMORY_LIMIT=256`에서 `MemoryWorker`의 Heap과 Linux가 보는 RSS가 계속 증가했고, 약 31초 뒤 애플리케이션이 종료됐습니다.

## 2. Evidence & Logs (증거 자료)

### 재현 경로

터미널 A에서 실행합니다.

```bash
MEMORY_LIMIT=256 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/oom-before.log"
```

터미널 B에서 가장 최근에 생성된 작업 PID를 관찰합니다.

```bash
PID="$(pgrep -n -x agent-leak-app)"
bash scripts/monitor.sh "$PID" 60 oom-before-monitor.log
```

[애플리케이션 로그](../evidence/oom-before/application.log)에는 Heap 증가와 종료 원인이 이어서 기록됐습니다.

```text
[MemoryWorker] Current Heap: 225MB
[MemoryWorker] Current Heap: 250MB
[MemoryWorker] Current Heap: 275MB
[MemoryGuard] Memory limit exceeded (275MB >= 256MB)
[MemoryGuard] Self-terminating process ...
```

[`monitor.sh` 결과](../evidence/oom-before/monitor.log)에서 RSS는 `17,920KiB`에서 `273,920KiB`까지 증가한 뒤 `PROCESS_EXITED`가 기록됐습니다. 앱 내부 Heap 증가가 실제 프로세스 메모리 증가로 이어진 증거입니다.

## 3. Root Cause Analysis (원인 분석)

직접적인 종료 원인은 Linux OOM Killer가 아니라 애플리케이션의 `MemoryGuard`입니다. 종료 직전에 앱이 제한 초과와 자기 종료 메시지를 직접 남겼습니다.

근본 문제는 `MemoryWorker`가 사용한 Heap을 계속 누적한다는 점입니다. 앱 내부 제한은 시스템 전체가 불안정해지기 전에 해당 프로세스를 중단하는 보호 장치로 동작했습니다.

## 4. Workaround & Verification (조치 및 검증)

```text
Before: MEMORY_LIMIT=256 → 약 31초 후 MemoryGuard 종료
After:  MEMORY_LIMIT=512 → 50회 관찰 완료 시까지 생존
```

After는 메모리 제한만 바꾸고 나머지 조건은 동일하게 유지했습니다.

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/oom-after.log"
```

[After `monitor.sh` 결과](../evidence/oom-after/monitor.log)에서는 RSS가 `17,920KiB`에서 `453,248KiB`까지 증가했지만 관찰 종료까지 프로세스가 살아 있었습니다. [실행 결과](../evidence/oom-after/result.txt)의 `stopped_by_observer=true`는 장애 종료가 아니라 관찰자가 실험을 마치고 종료했다는 뜻입니다.

제한을 높인 것은 메모리 누수를 고친 것이 아닙니다. 소스 코드를 수정할 수 있다면 불필요한 객체를 해제하고 캐시나 큐의 크기에 상한을 둬야 합니다.
