# [Deadlock] 두 작업 스레드의 교차 잠금과 무한 대기

## 1. Description (현상 설명)

OOM과 CPU 보호 종료가 발생하지 않도록 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`으로 설정한 상태에서 멀티스레드를 활성화하면 작업은 멈추지만 프로세스는 종료되지 않는다.

재현 설정은 다음과 같다.

```text
MEMORY_LIMIT=512
CPU_MAX_OCCUPY=40
MULTI_THREAD_ENABLE=true
```

마지막 애플리케이션 로그는 두 작업 스레드의 WAITING/BLOCKED 상태에서 멈췄다. 30초 관찰이 끝날 때까지 PID는 살아 있었으며, 관찰이 끝난 뒤에는 실험 스크립트가 남아 있는 프로세스를 정리했다.

## 2. Evidence & Logs (증거 자료)

Before 설정은 [settings.txt](../evidence/deadlock/before-20260913-203109-415113757/settings.txt), 생존 여부와 CPU·RSS 변화는 [run-summary.txt](../evidence/deadlock/before-20260913-203109-415113757/run-summary.txt)에 기록되어 있다.

[전체 애플리케이션 로그](../evidence/deadlock/before-20260913-203109-415113757/application-full.log)는 두 스레드의 자원 보유와 대기 관계를 보여준다.

```text
Worker-Thread-1: LOCK ACQUIRED [Shared_Memory_A]
Worker-Thread-2: LOCK ACQUIRED [Socket_Pool_B]
Worker-Thread-1: WAITING for [Socket_Pool_B] (Status: BLOCKED)
Worker-Thread-2: WAITING for [Shared_Memory_A] (Status: BLOCKED)
```

마지막 BLOCKED 로그 이후 약 22초 동안 새 작업 로그가 없었지만 PID는 계속 존재했다. [시간별 관제 자료](../evidence/deadlock/before-20260913-203109-415113757/metrics.tsv)는 다음 정체 상태를 보여준다.

```text
CPU: 9.5% → 0.4%
RSS: 17,792KiB → 17,920KiB
최종 스레드 수: 3
관찰 종료 시 PID 생존: true
```

[스레드 대기 위치](../evidence/deadlock/before-20260913-203109-415113757/thread-wait-channels.txt)에서는 세 스레드가 모두 `futex_wait_queue`에 있었다. `top -H`로 수집한 [스레드별 상태](../evidence/deadlock/before-20260913-203109-415113757/thread-top.txt)를 통해 각 스레드의 CPU 사용량과 실행 상태를 확인할 수 있다.

## 3. Root Cause Analysis (원인 분석)

Worker-Thread-1은 `Shared_Memory_A`를 잠근 뒤 `Socket_Pool_B`가 필요해졌고, Worker-Thread-2는 `Socket_Pool_B`를 잠근 뒤 `Shared_Memory_A`가 필요해졌다.

각 스레드는 상대 스레드가 보유한 자원을 기다리면서 자신이 가진 자원을 놓지 않는다. 이 순환 대기 때문에 어느 쪽도 다음 단계로 진행할 수 없다. PID 생존, 낮고 정체된 CPU, 거의 변하지 않는 RSS, futex 대기와 교차 WAITING/BLOCKED 로그가 함께 확인되므로 단순 종료나 일시적인 느림이 아니라 Deadlock으로 판단한다.

## 4. Workaround & Verification (조치 및 검증)

근본적으로 해결하려면 모든 스레드가 공유 자원을 같은 순서로 잠그게 하거나, 잠금 시간 제한과 실패 시 해제 정책을 적용해야 한다. 제공된 바이너리 내부 코드는 변경할 수 없으므로, 이번 과제에서는 다른 설정을 그대로 유지하고 `MULTI_THREAD_ENABLE`만 비활성화해 동시 실행을 피했다.

```text
Before: MULTI_THREAD_ENABLE=true
After:  MULTI_THREAD_ENABLE=false
```

After 설정은 [settings.txt](../evidence/deadlock/after-20260913-203213-163937858/settings.txt), Deadlock 미발생 판정은 [run-summary.txt](../evidence/deadlock/after-20260913-203213-163937858/run-summary.txt)에 기록되어 있다. 애플리케이션은 `MULTI_THREAD_ENABLE=false`를 `[OK]`로 판정했다.

[After 전체 로그](../evidence/deadlock/after-20260913-203213-163937858/application-full.log)에서는 다음 정상 진행을 확인할 수 있다.

```text
SYSTEM STATUS: STABLE
[Scheduler] All tasks completed.
상호 WAITING/BLOCKED 로그 없음
deadlock_observed=false
```

After에도 정상 모니터링 작업 때문에 세 스레드가 존재했고, 안정성 시험의 `MemoryWorker`가 함께 실행되어 RSS가 증가했다. 그러나 [After 스레드 대기 위치](../evidence/deadlock/after-20260913-203213-163937858/thread-wait-channels.txt)에서 보조 스레드는 `do_select` 상태였고, 교차 자원 대기 로그 없이 스케줄러 작업이 완료됐다. 따라서 스레드 수나 RSS 증가만으로 판단하지 않고 작업 완료와 대기 관계를 기준으로 Deadlock 회피를 검증했다. 30초 관찰 후에는 실험 스크립트가 살아 있는 프로세스를 종료했다.

이 조치는 잠금 순서 자체를 고친 근본 해결이 아니라, 멀티스레드 실행을 비활성화해 순환 대기 조건을 제거한 우회 방법이다.

자동 검증은 다음 명령으로 다시 수행할 수 있다.

```bash
./scripts/verify_deadlock_evidence.sh \
  evidence/deadlock/before-20260913-203109-415113757 \
  evidence/deadlock/after-20260913-203213-163937858
```
