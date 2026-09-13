# CPU 과점유 / CPU Latency 분석 요약

## 실험 조건

- Before: `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=80`, `MULTI_THREAD_ENABLE=true`
- After: `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`, `MULTI_THREAD_ENABLE=true`
- OOM이 먼저 발생하지 않도록 메모리 제한은 두 실험 모두 512MB로 고정했다.
- 두 CPU 실험 사이에는 `CPU_MAX_OCCUPY`만 변경했다.

## Before 관찰 결과

- 증거 폴더: `before-20260913-201340-113910967`
- 애플리케이션의 `[CpuWorker] Current Load` 값이 5.00%에서 55.11%까지 상승했다.
- 55.11%에서 `CPU Threshold Violated` 로그가 발생했다.
- 프로세스 종료 코드는 143이며, 이는 SIGTERM 종료에 해당한다.
- 실행부터 종료까지 40초가 걸렸다.
- `CPU_MAX_OCCUPY=80`은 부팅 시 `[WARNING: Recommend Under 50%]`로 판정됐다.

## 운영체제 관제값과의 차이

반복 저장한 `top`에서 `agent-leak-app` 프로세스의 최대 CPU 관측값은 5%였다. 이는 애플리케이션 내부 로그의 최대값 55.11%와 일치하지 않는다. `top`의 시스템 CPU 행도 대부분 유휴 상태로 나타났다.

따라서 내부 로그의 `Current Load`를 Linux 전체 CPU 사용률 또는 `top`의 프로세스 CPU 사용률과 같은 값이라고 단정할 수 없다. 이번 증거가 직접 보여주는 것은 애플리케이션 내부 `CpuWorker` 판정값이 계속 상승했고, 그 값을 기준으로 한 보호 정책이 프로세스에 SIGTERM을 보냈다는 사실이다.

## After 관찰 결과

- 증거 폴더: `after-20260913-201529-655062996`
- `CPU_MAX_OCCUPY=40`은 부팅 시 `[OK]`로 판정됐다.
- 60초 관찰 동안 `CpuWorker`와 `CPU Threshold Violated` 로그가 발생하지 않았다.
- CPU 임계치로 종료되지 않고 관찰 시간이 끝날 때까지 프로세스가 살아 있었다.
- 관찰 종료 후 실험 스크립트가 SIGTERM으로 프로세스를 정리했다. 이 SIGTERM은 CPU 보호 정책이 보낸 것이 아니다.
- CPU 조건을 통과한 뒤 WAITING/BLOCKED 상태가 나타났지만, Deadlock의 원인과 조치는 다음 단계에서 분석한다.

## 원인 분석

`CPU_MAX_OCCUPY=80`은 애플리케이션이 권장하는 50% 미만 범위를 벗어난 설정이다. 이 조건에서 `CpuWorker`가 시작되고 내부 부하 판정값이 증가하다 50%를 넘은 뒤 보호 정책이 SIGTERM으로 프로세스를 종료했다. 특히 설정값은 80%였지만 실제 보호 종료는 55.11%에서 발생했으므로, 보호 기준은 설정된 80% 자체가 아니라 프로그램이 별도로 적용하는 약 50% 안전 기준과 연결된 것으로 관찰된다.

## 우회 설정과 검증 결론

`CPU_MAX_OCCUPY`를 40으로 낮추자 CPU 설정이 정상 범위로 판정됐고, 같은 관찰 시간 동안 CPU 작업과 임계치 종료가 재현되지 않았다. 따라서 이 과제 환경에서는 50% 미만으로 설정하는 것이 CPU 보호 종료를 피하는 우회 방법이다.

다만 제공된 바이너리 내부의 부하 계산 방식이나 정책 로직을 수정한 것은 아니다. 또한 OS 관제값과 내부 판정값이 다르므로 최종 리포트에서는 두 값을 구분해 제시해야 한다.
