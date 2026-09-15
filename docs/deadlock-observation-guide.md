# Deadlock 관찰 과정

이 문서는 Deadlock 실험에서 애플리케이션 로그와 Linux 명령어를 어떻게 확인하고, 그 결과를 어떻게 해석하는지 설명합니다.

## 1. 실험 실행

다음 명령으로 `MULTI_THREAD_ENABLE=true` 설정의 Before 실험을 시작합니다.

```bash
./scripts/run_deadlock_experiment.sh before true
```

실험 스크립트가 앱을 실행하고, 앱의 출력 로그를 파일로 저장합니다. 이때 앱은 다음과 같은 자체 로그를 남깁니다.

```text
Worker-Thread-1 WAITING for [Socket_Pool_B]... (Status: BLOCKED)
Worker-Thread-2 WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```

이 로그는 애플리케이션이 직접 출력한 것입니다. 첫 번째 스레드는 두 번째 스레드가 가진 `Socket_Pool_B`를 기다리고, 두 번째 스레드는 첫 번째 스레드가 가진 `Shared_Memory_A`를 기다립니다.

## 2. 30초 동안 관찰

실험 스크립트는 기본적으로 1초 간격으로 30번 상태를 수집합니다. 이 과정에서 로그, CPU·메모리, 프로세스 상태를 증거 파일로 저장합니다.

앱 로그가 `WAITING/BLOCKED`에서 멈춘 뒤 새 작업 로그나 완료 로그를 남기지 않으면 작업이 진행되지 않는 상태로 볼 수 있습니다.

## 3. 프로세스가 살아 있는지 확인

프로세스는 실행 중인 프로그램입니다. Linux에서는 PID로 프로세스를 구분합니다. 이 실험의 PID는 `16535`였습니다.

스크립트는 내부적으로 다음과 같은 방식으로 PID가 아직 존재하는지 확인합니다.

```bash
ps -p 16535 -o pid=
```

- PID가 출력됨: 프로세스가 아직 실행 중
- 아무것도 출력되지 않음: 프로세스가 종료됨

실험에서는 30초가 지난 뒤에도 `agent-leak-app`의 PID `16535`가 확인됐습니다. 따라서 앱은 멈춰 있었지만 종료되지는 않았습니다.

## 4. `process_alive_after_observation=true`의 의미

이 값은 애플리케이션의 환경변수나 앱이 출력한 설정값이 아닙니다. 실험 스크립트가 Linux의 프로세스 확인 결과를 보고 자동으로 기록한 결과값입니다.

스크립트의 동작은 다음과 같습니다.

```text
처음 값: process_alive_after_observation=false
30초 관찰 종료
PID가 여전히 존재함
최종 값: process_alive_after_observation=true
```

따라서 이 값은 “관찰이 끝난 뒤에도 프로세스가 살아 있었는가?”에 대한 답입니다.

실행 요약에는 다음과 같이 저장됩니다.

```text
observation_seconds=30
process_alive_after_observation=true
deadlock_observed=true
```

## 5. 스레드가 어디서 기다리는지 확인

프로세스가 살아 있다는 것만으로는 작업이 정상적으로 진행된다고 할 수 없습니다. 그래서 스크립트는 Linux의 `ps -L` 명령으로 프로세스 안의 스레드 상태도 확인합니다.

```bash
ps -L -p 16535 -o pid,lwp,stat,wchan:40,%cpu,%mem,comm
```

여기서 `wchan`은 스레드가 커널 내부에서 대기 중인 위치입니다. 실험에서는 스레드가 다음 상태에 있었습니다.

```text
futex_wait_queue
```

`futex_wait_queue`는 다른 스레드가 잠금을 풀거나 조건을 만족하기를 기다리는 상태입니다. 두 스레드가 서로가 가진 자원을 기다리고 있으므로 교차 잠금에 의한 Deadlock으로 판단합니다.

## 6. 전체 흐름

```text
앱 실행
  -> 앱이 WAITING/BLOCKED 로그 출력
  -> 스크립트가 30초 동안 상태 수집
  -> Linux ps 명령으로 PID 존재 여부 확인
  -> PID가 남아 있어 process_alive_after_observation=true 기록
  -> ps -L 명령으로 스레드 대기 위치 확인
  -> futex_wait_queue에서 대기 중인 상태 확인
  -> 프로세스는 살아 있지만 작업은 멈춘 Deadlock으로 판단
```

## 7. 확인 결과와 판단의 구분

- **앱 로그:** 두 스레드가 서로의 자원을 기다린다는 사실을 보여줍니다.
- **Linux 명령어:** 프로세스와 스레드가 실제로 살아 있는지, 어디서 대기하는지 확인합니다.
- **스크립트 변수:** 명령어 확인 결과를 `run-summary.txt`에 저장합니다.
- **최종 판단:** 프로세스는 살아 있지만 스레드가 서로 잠금을 기다리므로 Deadlock입니다.
