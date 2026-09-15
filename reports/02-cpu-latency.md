# [Bug] CPU - 내부 Watchdog 부하 기준 초과와 SIGTERM 종료

## 1. Description (현상 설명)

OOM과 Deadlock이 섞이지 않도록 `MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false`로 고정했습니다. `CPU_MAX_OCCUPY=80`에서 앱이 기록하는 `CpuWorker` 부하 값이 상승하다가 내부 보호 기준을 넘었고, 약 29초 뒤 SIGTERM으로 종료됐습니다.

## 2. Evidence & Logs (증거 자료)

### 재현 경로

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=80 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/cpu-before.log"
```

다른 터미널에서 실행 초기에 생성된 상위 프로세스를 관찰합니다.

```bash
PID="$(pgrep -o -x agent-leak-app)"
bash scripts/monitor.sh "$PID" 60 cpu-before-monitor.log
top -p "$PID"
```

[애플리케이션 로그](../evidence/cpu-before/application.log)의 내부 부하 값은 `5.00%`에서 `53.32%`까지 상승했습니다.

```text
[CpuWorker] Current Load: 42.48%
[CpuWorker] Current Load: 46.78%
[CpuWorker] Current Load: 53.32%
[CpuWorker] CPU Threshold Violated! (53.32%).
```

[`monitor.sh` 결과](../evidence/cpu-before/monitor.log)에는 같은 프로세스가 사라진 `PROCESS_EXITED`가 기록됐고, [실행 결과](../evidence/cpu-before/result.txt)의 종료 코드는 `143`입니다. Linux에서 `128 + 15 = 143`이므로 SIGTERM 종료입니다.

다만 Linux가 측정한 `%CPU`는 약 `8.0%`에서 낮아졌으며 앱 내부값처럼 급상승하지 않았습니다. 제공 바이너리의 `Current Load`는 실제 OS CPU 사용률이 아니라 장애 재현을 위한 내부 판정값입니다. 이 차이를 실제 CPU 53% 사용으로 과장하지 않았습니다.

## 3. Root Cause Analysis (원인 분석)

`CPU_MAX_OCCUPY=80`은 앱이 부팅할 때 권장 범위를 벗어난 값으로 경고됩니다. 이 조건에서 실습 바이너리가 내부 부하 판정값을 올렸고, 값이 보호 기준을 넘자 `CPU Threshold Violated`를 기록한 뒤 SIGTERM으로 종료했습니다. PDF의 Watchdog 보호 동작에 해당합니다.

따라서 이번 장애의 직접 원인은 Linux CPU 포화가 아니라 **애플리케이션 내부 Watchdog 판정값 초과**입니다. Linux 관제값과 앱 내부값이 다르다는 사실 자체도 중요한 진단 결과입니다.

## 4. Workaround & Verification (조치 및 검증)

```text
Before: CPU_MAX_OCCUPY=80 → 약 29초 후 임계치 초과 및 SIGTERM
After:  CPU_MAX_OCCUPY=40 → 50회 관찰 완료 시까지 생존
```

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/cpu-after.log"
```

[After 앱 로그](../evidence/cpu-after/application.log)에는 `CPU Threshold Violated`가 없고, [After 실행 결과](../evidence/cpu-after/result.txt)에는 `stopped_by_observer=true`가 기록됐습니다. 즉, CPU 보호 정책이 종료한 것이 아니라 50회 관찰을 마친 뒤 실험자가 종료했습니다.

이 조치는 실제 서버의 CPU 성능을 개선한 것이 아닙니다. 소스 코드를 수정할 수 있다면 내부 부하 계산 방식과 임계치 로직을 실제 OS 지표와 대조해야 합니다.
