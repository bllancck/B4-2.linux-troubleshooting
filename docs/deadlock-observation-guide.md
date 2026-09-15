# Deadlock을 직접 확인하는 순서

Deadlock은 프로세스가 종료되는 장애가 아닙니다. **프로세스는 살아 있지만 작업이 더 진행되지 않는 상태**를 순서대로 확인해야 합니다.

## 1. 앱 로그에서 멈춘 지점 찾기

`MULTI_THREAD_ENABLE=true`로 실행하면 두 작업 스레드가 다음과 같은 로그를 남깁니다.

```text
Worker-Thread-1: LOCK ACQUIRED [Shared_Memory_A]
Worker-Thread-2: LOCK ACQUIRED [Socket_Pool_B]
Worker-Thread-1: WAITING for [Socket_Pool_B] (Status: BLOCKED)
Worker-Thread-2: WAITING for [Shared_Memory_A] (Status: BLOCKED)
```

이 로그만으로 알 수 있는 관계는 다음과 같습니다.

```text
Thread-1: A를 가진 채 B를 기다림
Thread-2: B를 가진 채 A를 기다림
```

두 스레드가 서로 필요한 자원을 가지고 있으므로 어느 쪽도 다음 단계로 갈 수 없습니다.

## 2. 프로세스가 살아 있는지 확인하기

다른 터미널에서 PID를 구하고 `ps`로 확인합니다.

```bash
PID="$(pgrep -n -x agent-leak-app)"
bash scripts/monitor.sh "$PID" 20 deadlock-before-monitor.log
ps -p "$PID" -o pid,stat,%cpu,rss,etime,comm
```

PID가 출력되면 프로세스는 아직 살아 있습니다. 실제 실험에서는 20회 관찰 동안 RSS가 `17,792KiB`로 고정됐고 CPU 누적 평균은 `7.3%`에서 `0.6%`로 낮아졌습니다. 앱 로그가 멈췄는데 PID가 존재하고 자원 변화도 정체된 것이 Deadlock을 의심할 첫 번째 근거입니다.

## 3. 스레드의 대기 위치 확인하기

```bash
ps -L -p "$PID" -o pid,lwp,stat,wchan:32,%cpu,comm
```

- `-L`: 프로세스가 아니라 스레드 단위로 표시
- `lwp`: 스레드 ID
- `stat`: 스레드 상태
- `wchan`: 커널 안에서 기다리는 위치

작업 스레드의 `wchan`에 `futex_wait_queue`가 나타나면 락과 관련된 대기 상태라는 뜻입니다. 이것만으로 Deadlock을 단정하지 않고, 앞의 교차 `WAITING/BLOCKED` 로그와 함께 판단합니다.

## 4. 판단하기

다음 세 조건이 함께 맞으면 Deadlock으로 판단합니다.

1. 두 스레드가 서로의 자원을 기다리는 로그가 있습니다.
2. 새 작업 로그와 완료 메시지가 나오지 않습니다.
3. PID는 살아 있고 스레드는 락 관련 위치에서 기다립니다.

최종 원본은 [앱 로그](../evidence/final/deadlock-before/application.log), [`monitor.sh` 결과](../evidence/final/deadlock-before/monitor.log), [프로세스 상태](../evidence/final/deadlock-before/process-final.txt), [스레드 대기 위치](../evidence/final/deadlock-before/threads-final.txt)에 나뉘어 있습니다.

## 5. 설정 변경 후 비교하기

`MULTI_THREAD_ENABLE=false`로 다시 실행합니다.

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/deadlock-after.log"
```

After에서는 상호 대기 로그가 없어지고 `[Scheduler] All tasks completed.`가 출력됩니다. 즉, 이번 조치는 멀티스레드 실행을 끄고 작업을 순서대로 처리해 교차 잠금 조건을 피한 것입니다. 소스 코드의 잠금 순서를 고친 근본 해결은 아닙니다.
