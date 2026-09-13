# OOM / Memory Leak 분석 요약

## 실험 조건

- Before: `MEMORY_LIMIT=256`, `CPU_MAX_OCCUPY=80`, `MULTI_THREAD_ENABLE=true`
- After: `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=80`, `MULTI_THREAD_ENABLE=true`
- 두 실험은 `MEMORY_LIMIT`만 변경했다.

## Before 관찰 결과

- 증거 폴더: `before-20260913-194113-782307006`
- 실행 초기에 RSS는 18,048KiB였다.
- RSS가 최대 274,048KiB까지 계속 증가했다.
- 애플리케이션 로그의 Heap 값도 25MB부터 275MB까지 단계적으로 증가했다.
- `275MB >= 256MB`에서 `MemoryGuard`가 제한 초과를 기록하고 프로세스를 스스로 종료했다.
- 종료까지 35초가 걸렸으며 프로세스 종료 코드는 137이었다.
- 관제 데이터의 마지막 행은 `PROCESS_EXITED`다.

## After 관찰 결과

- 증거 폴더: `after-20260913-195102-393699520`
- 부팅 검사에서 512MB 메모리 제한은 `[OK]`로 판정됐다.
- 관찰된 RSS는 18,048KiB로 유지됐고 `MemoryWorker`와 `Memory limit exceeded` 로그가 나타나지 않았다.
- OOM 대신 다음 우선순위 작업인 `CpuWorker`가 실행됐고, 이후 CPU 보호 기능이 프로세스를 종료했다.
- OOM 관찰 여부는 `false`다. CPU 장애의 원인과 조치는 다음 구현 단계에서 분석한다.

## 원인 분석

기본 설정에서는 `MemoryWorker`가 Heap을 약 25MB씩 반복적으로 늘렸다. 애플리케이션이 사용한 메모리를 실행 중에 반환하지 않아 RSS도 함께 증가했고, 내부 보호 기준인 256MB를 넘자 `MemoryGuard`가 시스템 불안정을 막기 위해 프로세스를 종료했다.

커널 경고 기록에는 이 실험과 관련된 Linux OOM Killer 동작이 없었고 종료 후에도 WSL 메모리가 충분히 남아 있었다. 따라서 운영체제가 메모리 부족으로 강제 종료한 것이 아니라 애플리케이션 내부 보호 기능이 의도적으로 종료한 것으로 판단한다.

## 우회 설정과 검증 결론

`MEMORY_LIMIT`를 허용 범위의 512MB로 높이자 메모리 설정이 정상 범위로 판정됐으며, 같은 관찰 과정에서 메모리 증가와 `MemoryGuard` 종료가 재현되지 않았다. 따라서 설정 변경은 이 과제 환경에서 OOM Crash를 피하는 우회 방법으로 확인됐다.

다만 제공된 바이너리 내부의 메모리 할당 방식을 수정한 것은 아니므로 메모리 누수 자체를 근본적으로 제거했다고 볼 수 없다. 또한 설정 변경 후 CPU 보호 기능이 별도로 동작했으므로 전체 프로그램이 안정화됐다는 의미도 아니다.

## 검증 대상에서 제외한 진단 자료

- `diagnostic-failed-launcher-pid-20260913-193201`: 바깥 실행 프로세스를 잘못 관찰한 첫 수집 자료
- `diagnostic-after-cpu-interference-20260913-194252`: 변경 후 성공 조건을 OOM 종료로 잘못 판단했던 수집 자료

두 폴더는 오류 원인을 숨기지 않기 위해 보존했지만 최종 Before & After 수치에는 사용하지 않는다.
