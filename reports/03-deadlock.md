# [Bug] Deadlock - 두 작업 스레드의 교차 잠금

## 1. Description (현상 설명)

메모리와 CPU 보호 종료를 피하도록 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`으로 고정했습니다. `MULTI_THREAD_ENABLE=true`에서는 두 작업 스레드가 서로의 자원을 기다리면서 로그 진행은 멈췄지만 프로세스는 종료되지 않았습니다.

## 2. Evidence & Logs (증거 자료)

### 재현 경로

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=true \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/deadlock-before.log"
```

다른 터미널에서 작업 PID를 확인합니다.

```bash
PID="$(pgrep -n -x agent-leak-app)"
bash scripts/monitor.sh "$PID" 20 deadlock-before-monitor.log
ps -p "$PID" -o pid,stat,%cpu,%mem,rss,etime,comm
ps -L -p "$PID" -o pid,lwp,stat,wchan:32,%cpu,%mem,rss,comm
```

[애플리케이션 로그](../evidence/final/deadlock-before/application.log)에서 자원 보유와 교차 대기 관계를 확인했습니다.

```text
Worker-Thread-1: LOCK ACQUIRED [Shared_Memory_A]
Worker-Thread-2: LOCK ACQUIRED [Socket_Pool_B]
Worker-Thread-1: WAITING for [Socket_Pool_B] (Status: BLOCKED)
Worker-Thread-2: WAITING for [Shared_Memory_A] (Status: BLOCKED)
```

[`monitor.sh` 결과](../evidence/final/deadlock-before/monitor.log)는 CPU가 `7.3%`에서 `0.6%`로 낮아지는 동안 RSS가 `17,792KiB`로 고정됐고, 20회 관찰 후에도 `PROCESS_EXITED`가 없음을 보여줍니다. [최종 프로세스 상태](../evidence/final/deadlock-before/process-final.txt)에도 PID가 남아 있습니다.

[스레드 대기 위치](../evidence/final/deadlock-before/threads-final.txt)에서는 세 스레드 모두 `futex_wait_queue`에서 기다리고 있었습니다.

## 3. Root Cause Analysis (원인 분석)

```text
Thread-1: 자원 A 보유 → 자원 B 대기
Thread-2: 자원 B 보유 → 자원 A 대기
```

두 자원은 한 번에 한 스레드만 사용할 수 있고, 각 스레드는 자원을 가진 채 다른 자원을 기다리며, 자원을 강제로 빼앗을 수 없고, 대기 관계가 원을 만듭니다. 상호 배제, 점유 대기, 비선점, 순환 대기 조건이 함께 성립한 Deadlock입니다.

## 4. Workaround & Verification (조치 및 검증)

```text
Before: MULTI_THREAD_ENABLE=true  → 교차 WAITING/BLOCKED, 작업 미완료
After:  MULTI_THREAD_ENABLE=false → 교차 대기 없음, 작업 완료
```

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/deadlock-after.log"
```

[After 앱 로그](../evidence/final/deadlock-after/application.log)에는 상호 `WAITING/BLOCKED`가 없고 `[Scheduler] All tasks completed.`가 기록됐습니다. [After 스레드 상태](../evidence/final/deadlock-after/threads-final.txt)의 보조 스레드는 `do_select` 또는 실행 상태이며 교차 자원 대기 관계가 없습니다.

멀티스레드를 끄는 것은 우회 조치입니다. 소스 코드를 수정할 수 있다면 모든 스레드가 자원을 같은 순서로 획득하게 하고, 락 타임아웃과 실패 시 해제 처리를 추가해야 합니다.
