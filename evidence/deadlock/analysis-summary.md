# Deadlock 분석 요약

## 실험 조건

- Before: `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`, `MULTI_THREAD_ENABLE=true`
- After: `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`, `MULTI_THREAD_ENABLE=false`
- OOM과 CPU 보호 종료가 먼저 발생하지 않도록 메모리와 CPU 설정은 두 실험에서 동일하게 유지했다.
- 두 Deadlock 실험 사이에는 `MULTI_THREAD_ENABLE`만 변경했다.

## Before 관찰 결과

- 증거 폴더: `before-20260913-203109-415113757`
- 30초 관찰이 끝날 때까지 PID가 살아 있었다.
- Worker-Thread-1은 `Shared_Memory_A`를 획득한 뒤 `Socket_Pool_B`를 기다렸다.
- Worker-Thread-2는 `Socket_Pool_B`를 획득한 뒤 `Shared_Memory_A`를 기다렸다.
- 두 로그 모두 `WAITING`과 `Status: BLOCKED`에서 멈췄다.
- 마지막 BLOCKED 로그 이후 약 22초 동안 새 작업 로그가 없었다.
- 세 스레드 모두 `futex_wait_queue`에서 대기하고 있었다.
- CPU는 9.5%에서 0.4%로 낮아졌고 RSS는 17,792KiB에서 17,920KiB로 거의 변하지 않았다.
- 프로세스가 종료된 것이 아니라 살아 있는 상태로 정체됐으며, 관찰 후 실험 스크립트가 정리했다.

## 원인 분석

두 작업 스레드가 자원을 서로 반대 순서로 획득했다. Thread-1은 A를 보유한 채 B를 기다리고, Thread-2는 B를 보유한 채 A를 기다렸다. 어느 스레드도 자신이 가진 자원을 놓지 못하므로 서로의 진행을 영구적으로 막는 순환 대기 상태가 됐다.

PID 생존, CPU·RSS 정체, 세 스레드의 futex 대기, 상호 WAITING/BLOCKED 로그가 동시에 확인되므로 단순 종료나 느린 처리보다 Deadlock으로 판단할 근거가 충분하다.

## After 관찰 결과

- 증거 폴더: `after-20260913-203213-163937858`
- `MULTI_THREAD_ENABLE=false`가 부팅 검사에서 `[OK]`로 판정됐다.
- `SYSTEM STATUS: STABLE`과 `[Scheduler] All tasks completed.` 로그가 기록됐다.
- 상대 자원을 기다리는 WAITING/BLOCKED 로그가 나타나지 않았다.
- 30초 관찰이 끝날 때까지 PID가 살아 있었고, 관찰 후 실험 스크립트가 종료했다.
- 정상 모니터링 작업 때문에 최종 스레드 수는 3이었지만, 두 보조 스레드의 대기 위치는 Deadlock 때의 `futex_wait_queue`가 아니라 `do_select`였다.
- RSS 증가는 안정성 시험의 `MemoryWorker`가 함께 실행된 결과이며 Deadlock 재발 증거는 아니다.

## 우회 설정과 검증 결론

`MULTI_THREAD_ENABLE=false`로 변경하자 동시에 반대 순서로 자원을 획득하는 흐름이 사라지고 스케줄러 작업이 완료됐다. 따라서 이 과제 환경에서는 멀티스레드 실행을 비활성화하는 것이 Deadlock을 피하는 우회 방법이다.

이는 제공된 바이너리 내부의 잠금 순서 자체를 수정한 근본 해결은 아니다. 실제 코드 수정이 가능하다면 모든 스레드가 자원을 같은 순서로 획득하도록 만들거나, 잠금 시간 제한과 실패 시 해제 정책을 적용해야 한다.
