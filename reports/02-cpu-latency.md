# [CPU] CpuWorker 내부 부하 판정 상승과 SIGTERM 종료

## 1. Description (현상 설명)

OOM 조건을 제거하기 위해 `MEMORY_LIMIT=512`로 고정한 뒤 `CPU_MAX_OCCUPY=80`으로 실행하면 `CpuWorker`의 내부 부하 판정값이 계속 증가한다. 값이 55.11%에 도달하면 `CPU Threshold Violated`가 기록되고 프로세스가 SIGTERM으로 종료된다.

재현 설정은 다음과 같다.

```text
MEMORY_LIMIT=512
CPU_MAX_OCCUPY=80
MULTI_THREAD_ENABLE=true
```

부팅 검사에서도 이 값은 `[WARNING: Recommend Under 50%]`로 판정된다.

## 2. Evidence & Logs (증거 자료)

Before 설정은 [settings.txt](../evidence/cpu/before-20260913-201340-113910967/settings.txt), 종료 신호와 최대 관측값은 [run-summary.txt](../evidence/cpu/before-20260913-201340-113910967/run-summary.txt)에 기록되어 있다.

[CpuWorker 시간별 로그](../evidence/cpu/before-20260913-201340-113910967/cpu-worker-load.tsv)는 내부 부하 판정값의 상승을 보여준다.

```text
초기 내부 판정값:  5.00%
최대 내부 판정값: 55.11%
종료 로그:         CPU Threshold Violated
종료 코드:         143
종료 신호:         SIGTERM
```

[전체 애플리케이션 로그](../evidence/cpu/before-20260913-201340-113910967/application-full.log)의 마지막 구간은 다음과 같다.

```text
[CpuWorker] Current Load: 46.76%
[CpuWorker] Current Load: 49.88%
[CpuWorker] Current Load: 55.11%
[CpuWorker] CPU Threshold Violated! (55.11%).
```

제공된 바이너리는 종료 주체를 `[WATCHDOG]`라는 이름으로 출력하지 않는다. 대신 `CPU Threshold Violated` 로그 직후 종료 코드 143을 반환하며, 143은 SIGTERM 신호로 종료되었음을 뜻한다. 이 보고서에서는 이 두 증거를 Watchdog 종료 동작의 근거로 사용한다.

운영체제의 반복 측정값인 [top-timeseries.txt](../evidence/cpu/before-20260913-201340-113910967/top-timeseries.txt)에서 해당 프로세스의 최대 CPU는 5%였다. [metrics.tsv](../evidence/cpu/before-20260913-201340-113910967/metrics.tsv)의 마지막 행은 임계치 로그 직후 프로세스가 종료된 것을 보여준다.

## 3. Root Cause Analysis (원인 분석)

`CPU_MAX_OCCUPY=80`은 프로그램이 권장하는 50% 미만 범위를 벗어난 값이다. 이 조건에서 `CpuWorker`가 시작되고 내부 부하 판정값이 상승하다 약 50% 안전 기준을 넘자 보호 정책이 SIGTERM을 보내 프로세스를 종료했다.

설정값이 80%인데도 55.11%에서 종료됐으므로 실제 보호 기준은 설정된 80% 자체가 아니라 애플리케이션이 별도로 적용하는 약 50% 기준과 연결된 것으로 관찰된다.

또한 내부 `Current Load` 최대값 55.11%와 Linux `top`의 프로세스 최대값 5%는 일치하지 않는다. 따라서 내부 판정값을 시스템 전체 CPU 사용률이나 OS가 측정한 프로세스 CPU 사용률이라고 단정할 수 없다. 확인 가능한 원인은 내부 CpuWorker 판정값에 반응한 보호 정책이며, Linux 전체 CPU 포화는 현재 증거로 입증되지 않는다.

## 4. Workaround & Verification (조치 및 검증)

`CPU_MAX_OCCUPY`만 권장 범위 안의 40으로 낮췄다.

```text
Before: CPU_MAX_OCCUPY=80
After:  CPU_MAX_OCCUPY=40
```

After 설정은 [settings.txt](../evidence/cpu/after-20260913-201529-655062996/settings.txt), 생존 및 임계치 판정은 [run-summary.txt](../evidence/cpu/after-20260913-201529-655062996/run-summary.txt)에 기록되어 있다.

변경 후 결과는 다음과 같다.

```text
CpuWorker 임계치 로그:       없음
CPU Threshold Violated:      없음
60초 관찰 종료 시 PID 생존: true
cpu_threshold_observed:      false
```

After의 종료 코드도 143이지만 이는 CPU 보호 정책이 아니라, 60초 관찰을 마친 실험 스크립트가 살아 있는 프로세스를 정리하면서 보낸 SIGTERM이다. [After 전체 로그](../evidence/cpu/after-20260913-201529-655062996/application-full.log)에는 CPU 임계치 메시지가 없고 다음 Deadlock 조건의 로그가 나타난다.

자동 검증은 다음 명령으로 다시 수행할 수 있다.

```bash
./scripts/verify_cpu_evidence.sh \
  evidence/cpu/before-20260913-201340-113910967 \
  evidence/cpu/after-20260913-201529-655062996
```
