# Linux 시스템 장애 분석

`agent-leak-app`에서 OOM Crash, CPU Latency, Deadlock을 직접 관찰하는 실습입니다.

스크립트는 환경 준비용 `setup.sh`와 CPU·메모리를 기록하는 짧은 `monitor.sh`만 사용합니다. 장애 실행과 원인 판정은 Linux 명령어를 직접 보며 진행합니다.

## 실습 결과 요약

| 장애 | Before | 바꾼 값 | After |
| --- | --- | --- | --- |
| OOM Crash | Heap과 RSS가 증가한 뒤 `MemoryGuard`가 종료 | `MEMORY_LIMIT=256 → 512` | 메모리 제한 초과가 발생하지 않음 |
| CPU Latency | 내부 부하 값이 상승한 뒤 SIGTERM 종료 | `CPU_MAX_OCCUPY=80 → 40` | CPU 보호 종료가 발생하지 않음 |
| Deadlock | PID는 살아 있지만 두 스레드가 서로 대기 | `MULTI_THREAD_ENABLE=true → false` | 작업이 순서대로 완료됨 |

## 실행 환경

- 운영체제: Linux 또는 WSL
- 셸: Bash
- 지원 CPU: x86_64/amd64, arm64/aarch64
- 필수 패키지: `unzip`, `procps`, `iproute2`
- 실행 계정: root가 아닌 일반 사용자
- 권장 환경: 로컬 PC 또는 Docker·WSL 같은 격리 환경

`setup.sh`가 CPU 아키텍처를 확인한 뒤 `agent-app-leak.zip`에서 알맞은 실행 파일을 선택합니다.

## 환경변수

| 변수 | 실습 범위 | 의미 |
| --- | --- | --- |
| `MEMORY_LIMIT` | 50~512 | 애플리케이션 메모리 제한(MB) |
| `CPU_MAX_OCCUPY` | 10~100 | 애플리케이션 내부 CPU 설정 |
| `MULTI_THREAD_ENABLE` | `true` 또는 `false` | 멀티스레드 작업 사용 여부 |

경로와 포트는 `setup.sh`가 만든 `agent.env`에서 설정합니다. 실험할 때는 위 세 변수만 바꿉니다.

## 제약 사항

- 애플리케이션은 `0.0.0.0:15034`를 사용하므로 해당 포트가 비어 있어야 합니다.
- 기본 작업 경로는 `$HOME/agent-leak-lab`이며 현재 사용자가 디렉터리를 만들고 쓸 수 있어야 합니다.
- OOM 실험은 실제 메모리를 최대 수백 MB까지 사용합니다. 다른 중요한 작업이 없는 환경에서 실행합니다.
- 실험이 끝난 뒤 `agent-leak-app` 프로세스가 남아 있으면 다음 실험의 포트 사용과 PID 확인에 영향을 줍니다.
- 공유 네트워크에서는 방화벽과 포트 노출 여부를 확인합니다.
- 제공된 바이너리를 디컴파일하거나 리버스 엔지니어링하지 않습니다.


## 1. 준비

Linux 또는 WSL의 일반 사용자 계정에서 실행합니다. OOM 실험은 실제 메모리를 사용하며 애플리케이션은 고정 포트 `15034`를 사용합니다.

```bash
sudo apt update
sudo apt install unzip procps iproute2

bash scripts/setup.sh
source "$HOME/agent-leak-lab/agent.env"
```

`setup.sh`가 하는 일은 다음 다섯 가지입니다.

1. CPU 아키텍처에 맞는 실행 파일을 압축에서 꺼냅니다.
2. 실습용 디렉터리를 `$HOME/agent-leak-lab`에 만듭니다.
3. 필요한 `secret.key`를 만듭니다.
4. 공통 경로가 담긴 `agent.env`를 만듭니다.
5. 고정 포트 `15034`를 사용할 수 있는지 확인합니다.

다른 작업 경로를 사용하려면 절대 경로를 인수로 전달합니다.

```bash
bash scripts/setup.sh "$HOME/my-agent-lab"
source "$HOME/my-agent-lab/agent.env"
```

## 2. 관찰 방법

터미널을 두 개 사용하면 흐름을 이해하기 쉽습니다.

- 터미널 A: 애플리케이션을 실행하고 로그를 봅니다.
- 터미널 B: `ps`나 `top`으로 Linux가 보는 프로세스 상태를 확인합니다.

이 앱은 같은 이름의 상위 프로세스와 작업 프로세스를 만듭니다. 메모리와 스레드는 가장 최근에 생성된 작업 PID를, CPU 종료 여부는 먼저 생성된 상위 PID를 확인합니다.

```bash
# 메모리와 Deadlock 관찰
WORKER_PID="$(pgrep -n -x agent-leak-app)"

# CPU 관찰
APP_PID="$(pgrep -o -x agent-leak-app)"

pgrep -af agent-leak-app
```

`monitor.sh`는 지정한 PID의 CPU, 메모리, RSS를 1초마다 화면과 파일에 기록합니다.

```bash
bash scripts/monitor.sh <PID> <관찰 횟수> <저장 파일>
```

다음 실험 전에는 터미널 A에서 `Ctrl+C`로 이전 실행을 끝내고 `pgrep -af agent-leak-app`에 남은 프로세스가 없는지 확인합니다.

## 3. OOM 관찰

### Before: 메모리 제한 256MB

터미널 A:

```bash
MEMORY_LIMIT=256 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/oom-before.log"
```

터미널 B:

```bash
WORKER_PID="$(pgrep -n -x agent-leak-app)"
bash scripts/monitor.sh "$WORKER_PID" 60 oom-before-monitor.log
```

확인할 내용은 두 가지입니다.

- 앱 로그: `Current Heap`이 증가하고 `Memory limit exceeded`가 나타나는가?
- `monitor.sh`: RSS가 시간에 따라 증가한 뒤 `PROCESS_EXITED`가 기록되는가?

### After: 메모리 제한 512MB

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/oom-after.log"
```

같은 방법으로 50회 이상 관찰해 Before 종료 시점을 넘겨도 살아 있는지 확인합니다. 이 설정은 누수 코드를 고친 것이 아니라 메모리 보호 종료를 늦춘 우회 조치입니다.
<br>

자세한 분석은 [reports/01-oom-crash.md](reports/01-oom-crash.md) 에서 확인할 수 있습니다. 

## 4. CPU 관찰

OOM과 Deadlock이 섞이지 않도록 두 실행 모두 `MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false`를 사용합니다.

### Before: CPU 설정 80

터미널 A:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=80 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/cpu-before.log"
```

터미널 B:

```bash
APP_PID="$(pgrep -o -x agent-leak-app)"
bash scripts/monitor.sh "$APP_PID" 60 cpu-before-monitor.log
top -p "$APP_PID"
```

앱 로그의 `Current Load`와 Linux `top`의 `%CPU`는 서로 다른 값입니다. 이 바이너리에서는 내부값만 상승하고 Linux 실측값은 상승하지 않았습니다. 내부 부하 판정값이 안전 기준을 넘으면 `CPU Threshold Violated`를 남기고 SIGTERM으로 종료됩니다.

### After: CPU 설정 40

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/cpu-after.log"
```

`CPU Threshold Violated` 없이 Before 종료 시점을 넘겨 50회 관찰이 완료되는지 확인합니다.

자세한 분석은 [reports/02-cpu-latency.md](reports/02-cpu-latency.md) 에서 확인할 수 있습니다.

## 5. Deadlock 관찰

메모리와 CPU 장애를 피하기 위해 두 실행 모두 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`을 사용합니다.

### Before: 멀티스레드 사용

터미널 A:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=true \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/deadlock-before.log"
```

`WAITING`과 `BLOCKED`에서 로그 진행이 멈추면 터미널 B에서 확인합니다.

```bash
PID="$(pgrep -n -x agent-leak-app)"

# CPU와 메모리 정체를 파일로 기록
bash scripts/monitor.sh "$PID" 20 deadlock-before-monitor.log

# 프로세스가 아직 살아 있는가?
ps -p "$PID" -o pid,stat,%cpu,rss,etime,comm

# 각 스레드는 어디에서 기다리는가?
ps -L -p "$PID" -o pid,lwp,stat,wchan:32,%cpu,comm
```

PID가 살아 있고 작업 로그는 멈췄으며 작업 스레드가 `futex_wait_queue`에서 기다리면 교차 잠금에 의한 Deadlock으로 판단할 수 있습니다. 확인 후 `Ctrl+C`로 종료합니다.

### After: 멀티스레드 사용 안 함

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE=false \
  "$AGENT_BINARY" 2>&1 | tee "$AGENT_LOG_DIR/deadlock-after.log"
```

상호 `WAITING/BLOCKED`가 사라지고 `[Scheduler] All tasks completed.`가 출력되는지 확인합니다.

자세한 분석은 [reports/03-deadlock.md](reports/03-deadlock.md) 에서 확인할 수 있습니다.

## 6. 결과를 읽는 순서

한꺼번에 모든 파일을 볼 필요는 없습니다. 장애마다 다음 순서만 지킵니다.

1. 터미널 A의 앱 로그에서 현상을 찾습니다.
2. 필요한 Linux 명령어 하나로 앱 밖의 상태를 확인합니다.
3. 환경변수 하나를 바꿔 다시 실행합니다.
4. Before와 After의 차이를 적습니다.

저장소의 `evidence/`는 이미 수행한 실험의 원본 기록입니다. 처음에는 [증거 읽기 안내](evidence/README.md)에 표시된 핵심 파일만 보면 됩니다.

## 프로젝트 구조

```text
.
├── agent-app-leak.zip       # 제공된 Linux 실행 파일
├── scripts/
│   ├── setup.sh             # 최초 한 번 실행하는 환경 준비 스크립트
│   └── monitor.sh           # PID의 CPU·메모리를 1초마다 기록
├── evidence/                # 실험의 원본 로그와 Linux 관찰 결과
└── reports/                 # 장애별 분석 리포트 3건
```

문제가 생기면 자동 검증 스크립트를 찾기보다 먼저 앱 로그의 마지막 줄, `pgrep -af agent-leak-app`, 그리고 해당 장애의 Linux 관찰 명령을 차례로 확인합니다.
