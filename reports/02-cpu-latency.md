# [CPU] 의도적으로 주입된 CpuWorker 부하 판정 상승과 SIGTERM 종료

## 1. Description (현상 설명)

OOM 조건을 제거하기 위해 `MEMORY_LIMIT=512`로 고정한 뒤 `CPU_MAX_OCCUPY=80`으로 실행하면 `CpuWorker`의 내부 부하 판정값이 계속 증가한다. 값이 55.11%에 도달하면 `CPU Threshold Violated`가 기록되고 프로세스가 SIGTERM으로 종료된다.

이 현상은 운영 중 우연히 발생한 실제 CPU 포화가 아니라, 제공된 실습용 바이너리가 트러블슈팅 훈련을 위해 의도적으로 주입한 CPU 장애 시나리오로 해석한다. 애플리케이션이 출력한 `Current Load`는 내부 판정값이며 Linux `top`이 측정한 프로세스 CPU 사용률과 동일한 지표가 아니다.

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

제공된 바이너리는 과제 예시와 달리 종료 주체를 `[WATCHDOG]`라는 이름으로 출력하지 않는다. 대신 `CPU Threshold Violated` 로그 직후 종료 코드 143을 반환하며, 143은 SIGTERM 신호로 종료되었음을 뜻한다. 따라서 특정 로그 문자열의 일치 여부보다 내부 부하 판정에 따른 보호 종료라는 동작과 종료 신호를 증거로 사용한다.

운영체제의 반복 측정값인 [top-timeseries.txt](../evidence/cpu/before-20260913-201340-113910967/top-timeseries.txt)에서 해당 프로세스의 최대 CPU는 5%였다. [metrics.tsv](../evidence/cpu/before-20260913-201340-113910967/metrics.tsv)의 마지막 행은 임계치 로그 직후 프로세스가 종료된 것을 보여준다.

## 3. Root Cause Analysis (원인 분석)

`agent-leak-app`은 OOM, CPU 과점유, Deadlock을 의도적으로 발생시키도록 제공된 실습용 바이너리다. `CPU_MAX_OCCUPY=80`은 프로그램이 권장하는 50% 미만 범위를 벗어난 값이며, 이 조건에서 CPU 장애 주입 경로인 `CpuWorker`가 시작됐다. 내부 부하 판정값은 약 3초 간격으로 5.00%에서 55.11%까지 단계적으로 증가했고, 약 50% 안전 기준을 넘자 보호 정책이 SIGTERM으로 프로세스를 종료했다.

설정값이 80%인데도 55.11%에서 종료됐으므로 실제 보호 기준은 설정된 80% 자체가 아니라 애플리케이션이 별도로 적용하는 약 50% 기준과 연결된 것으로 관찰된다.

또한 내부 `Current Load` 최대값 55.11%와 Linux `top`의 프로세스 최대값 5%는 일치하지 않는다. 같은 구간에서 운영체제 CPU도 대부분 유휴 상태였으므로, 내부값은 실제 Linux CPU 사용률이 아니라 장애 재현을 위한 시뮬레이션 값 또는 애플리케이션 고유 판정값으로 보는 것이 타당하다. 확인 가능한 원인은 의도적으로 증가한 내부 CpuWorker 판정값에 보호 정책이 반응한 것이며, Linux 전체 CPU 포화는 발생하지 않았다.

다만 소스 코드가 제공되지 않았으므로 내부값의 정확한 계산 방식까지 확정할 수는 없다. 위 결론은 시간에 따른 내부 로그, 운영체제 측정값, 설정 변경 전후 동작을 함께 비교한 관찰 기반 해석이다.

## 4. Workaround & Verification (조치 및 검증)

의도적으로 주입되는 CPU 장애 시나리오를 회피하기 위해 `CPU_MAX_OCCUPY`만 권장 범위 안의 40으로 낮췄다. 이는 실제 서버의 CPU 성능을 개선한 조치가 아니라, 실습 바이너리의 장애 유발 조건을 비활성화하는 설정 조치다.

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

After의 종료 코드도 143이지만 이는 CPU 보호 정책이 아니라, 60초 관찰을 마친 실험 스크립트가 살아 있는 프로세스를 정리하면서 보낸 SIGTERM이다. [After 전체 로그](../evidence/cpu/after-20260913-201529-655062996/application-full.log)에는 CPU 임계치 메시지가 없고 다음 Deadlock 조건의 로그가 나타난다. 따라서 Before의 143은 `CPU Threshold Violated` 직후 발생한 보호 종료이고, After의 143은 관찰 종료 후 테스트 스크립트가 수행한 정리 동작으로 구분된다.

자동 검증은 다음 명령으로 다시 수행할 수 있다.

```bash
./scripts/verify_cpu_evidence.sh \
  evidence/cpu/before-20260913-201340-113910967 \
  evidence/cpu/after-20260913-201529-655062996
```
