# [CPU] 의도적으로 주입된 CpuWorker 부하 판정 상승과 SIGTERM 종료

## 1. Description (현상 설명)

OOM 조건을 제거하기 위해 `MEMORY_LIMIT=512`로 고정한 뒤 `CPU_MAX_OCCUPY=80`으로 실행하면 `CpuWorker`의 내부 부하 판정값이 계속 증가한다. 값이 55.11%에 도달하면 `CPU Threshold Violated`가 기록되고 프로세스가 SIGTERM으로 종료된다.

부팅 검사에서 `CPU_MAX_OCCUPY=80`은 `[WARNING: Recommend Under 50%]`로 판정됐다.

재현 설정은 다음과 같다.

```text
MEMORY_LIMIT=512
CPU_MAX_OCCUPY=80
MULTI_THREAD_ENABLE=true
```

## 2. Evidence & Logs (증거 자료)

Before 설정은 [settings.txt](../evidence/cpu/before-20260913-201340-113910967/settings.txt)에서 확인할 수 있다.

[CpuWorker 시간별 로그](../evidence/cpu/before-20260913-201340-113910967/cpu-worker-load.tsv)는 내부 부하 판정값의 상승을 보여준다.

```text
초기 내부 판정값:  5.00%
최대 내부 판정값: 55.11%
```

[전체 애플리케이션 로그](../evidence/cpu/before-20260913-201340-113910967/application-full.log)의 마지막 구간은 다음과 같다.

```text
[CpuWorker] Current Load: 46.76%
[CpuWorker] Current Load: 49.88%
[CpuWorker] Current Load: 55.11%
[CpuWorker] CPU Threshold Violated! (55.11%).
```

제공된 바이너리는 실제 CPU 과점유를 감지한 것이 아니라 `CpuWorker`가 내부 부하 판정값을 높여 장애를 재현한다. 같은 구간의 Linux [top-timeseries.txt](../evidence/cpu/before-20260913-201340-113910967/top-timeseries.txt)에서 프로세스 CPU 사용률이 최대 5%에 그친 점도 내부 판정값이 실제 CPU 사용률과 다르다는 것을 보여준다. 따라서 종료 직전에는 과제 예시의 `[WATCHDOG]` 대신 `[CpuWorker] CPU Threshold Violated`가 기록된다.

애플리케이션은 20:14:18에 `CPU Threshold Violated`를 기록했고, [metrics.tsv](../evidence/cpu/before-20260913-201340-113910967/metrics.tsv)는 다음 측정 시점인 20:14:19에 `PROCESS_EXITED`를 기록했다. 실험 스크립트가 수집한 실행 시간 40초와 종료 코드 `143`(SIGTERM)은 [run-summary.txt](../evidence/cpu/before-20260913-201340-113910967/run-summary.txt)에서 확인할 수 있다.

## 3. Root Cause Analysis (원인 분석)

`CPU_MAX_OCCUPY=80`은 프로그램이 권장하는 50% 미만 범위를 벗어난 설정이다. 이 조건에서 `CpuWorker`의 내부 부하 판정값이 55.11%까지 상승하자 보호 정책이 프로세스를 SIGTERM으로 종료했다. 따라서 직접적인 종료 원인은 Linux CPU 포화가 아니라 애플리케이션 내부 부하 기준의 초과다.

내부값 55.11%와 Linux `top`의 최대값 5%가 크게 다르고 시스템 CPU도 대부분 유휴 상태였으므로, `Current Load`는 실제 Linux CPU 사용률이 아닌 애플리케이션 고유의 판정값으로 본다. 또한 설정값은 80%지만 종료는 55.11%에서 발생했으므로, 보호 정책은 설정값과 별도로 약 50%의 안전 기준을 적용한 것으로 추정된다.

소스 코드가 제공되지 않아 내부값의 계산 방식과 정확한 보호 기준은 확인할 수 없다. 위 원인 분석은 로그, 운영체제 측정값, 종료 시점을 종합한 관찰 기반 판단이다.

## 4. Workaround & Verification (조치 및 검증)

의도적으로 주입되는 CPU 장애 시나리오를 회피하기 위해 `CPU_MAX_OCCUPY`만 권장 범위 안의 40으로 낮췄다. 이는 실제 서버의 CPU 성능을 개선한 조치가 아니라, 실습 바이너리의 장애 유발 조건을 비활성화하는 설정 조치다.

```text
Before: CPU_MAX_OCCUPY=80
After:  CPU_MAX_OCCUPY=40
```

After 설정은 [settings.txt](../evidence/cpu/after-20260913-201529-655062996/settings.txt), 생존 및 임계치 판정은 [run-summary.txt](../evidence/cpu/after-20260913-201529-655062996/run-summary.txt)에 기록되어 있다. 애플리케이션은 `CPU_MAX_OCCUPY=40`을 권장 범위 안의 값인 `[OK]`로 판정했다.

변경 후 결과는 다음과 같다.

```text
CpuWorker 임계치 로그:       없음
CPU Threshold Violated:      없음
60초 관찰 종료 시 PID 생존: true
cpu_threshold_observed:      false
```

After의 종료 코드도 143이지만 이는 CPU 보호 정책이 아니라, 60초 관찰을 마친 실험 스크립트가 살아 있는 프로세스를 정리하면서 보낸 SIGTERM이다. [After 전체 로그](../evidence/cpu/after-20260913-201529-655062996/application-full.log)에는 CPU 임계치 메시지가 없고 다음 Deadlock 조건의 로그가 나타난다. 따라서 Before의 143은 `CPU Threshold Violated` 직후 발생한 보호 종료이고, After의 143은 관찰 종료 후 테스트 스크립트가 수행한 정리 동작으로 구분된다.

이 조치는 제공된 바이너리의 부하 계산 방식이나 보호 정책을 수정한 근본 해결이 아니라, 실습 환경에서 CPU 장애 유발 조건을 피하는 설정상 우회 방법이다.

자동 검증은 다음 명령으로 다시 수행할 수 있다.

```bash
./scripts/verify_cpu_evidence.sh \
  evidence/cpu/before-20260913-201340-113910967 \
  evidence/cpu/after-20260913-201529-655062996
```
