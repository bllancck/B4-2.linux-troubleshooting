# Linux 시스템 장애 분석

## 프로젝트 목적

제공된 `agent-leak-app`을 Linux 환경에서 실행해 OOM, CPU 과점유, Deadlock을 재현·분석하는 프로젝트입니다.

로그와 시스템 지표로 장애 원인을 규명하고, 설정 변경 전후를 비교해 조치 효과를 검증합니다.

수집한 증거와 분석 결과는 GitHub Issue 형식의 리포트로 정리합니다.

## 프로젝트 구조

```text
.
├── agent-app-leak.zip              # 제공된 실행 파일 압축본
├── scripts/
│   ├── prepare_environment.sh      # Linux 실행 환경 준비 및 검증
│   ├── verify_startup.sh           # 애플리케이션 정상 부팅과 PID 확인
│   ├── monitor.sh                  # PID의 CPU·메모리 변화 수집
│   ├── collect_evidence.sh         # 설정·로그·프로세스·스레드 증거 수집
│   ├── run_oom_experiment.sh       # OOM Before & After 실험
│   ├── verify_oom_evidence.sh      # OOM 증거 검증
│   ├── run_cpu_experiment.sh       # CPU Before & After 실험
│   ├── verify_cpu_evidence.sh      # CPU 증거 검증
│   ├── run_deadlock_experiment.sh  # Deadlock Before & After 실험
│   ├── verify_deadlock_evidence.sh # Deadlock 증거 검증
│   └── verify_reports.sh           # 리포트 구조와 증거 링크 검증
├── evidence/
│   ├── oom/                        # OOM 원본 증거와 분석 요약
│   ├── cpu/                        # CPU 원본 증거와 분석 요약
│   └── deadlock/                   # Deadlock 원본 증거와 분석 요약
└── reports/
    ├── 01-oom-crash.md             # OOM 장애 리포트
    ├── 02-cpu-latency.md           # CPU 장애 리포트
    └── 03-deadlock.md              # Deadlock 장애 리포트
```

구성은 다음 네 영역으로 나뉩니다.

- `scripts/`: 환경 준비, 장애 실험, 증거 수집 및 결과 검증 자동화
- `evidence/`: OOM, CPU, Deadlock 실험에서 수집한 원본 자료와 분석 요약
- `reports/`: 현상, 증거, 원인, 조치 순서로 작성한 GitHub Issue 형식 리포트
- `agent-app-leak.zip`: CPU 아키텍처별 실습용 바이너리가 포함된 제공 파일

## 실행 방법

### 1. 필요한 프로그램 확인

Linux 또는 WSL 환경이 필요합니다. 스크립트와 애플리케이션은 root가 아닌 일반 사용자 계정으로 실행해야 합니다.

일반 사용자 계정으로 실행하는 이유는 다음과 같습니다.

- 이 애플리케이션은 OOM, CPU 과점유, Deadlock을 의도적으로 재현하므로 최소 권한으로 실행해야 파일·프로세스 등 시스템 자원에 미칠 수 있는 영향을 줄일 수 있습니다.
- 환경 파일, 로그, API 키, 증거 자료를 `$HOME/agent-leak-lab` 아래에 생성합니다. root로 실행하면 파일이 `/root`에 생성되거나 root 소유가 되어 이후 일반 사용자가 접근하거나 실험을 반복할 때 권한 문제가 발생할 수 있습니다.
- 애플리케이션이 사용하는 15034번 포트는 관리자 권한이 필요한 포트가 아니므로 root 권한을 부여할 필요가 없습니다.

이를 보장하기 위해 준비·검증·실험 스크립트는 실행 시 사용자 ID를 확인하고 root 계정이면 즉시 중단합니다.

아래의 `sudo apt` 명령은 필수 패키지를 설치할 때만 사용합니다. 환경 준비와 장애 실험 스크립트는 `sudo` 없이 일반 사용자 권한으로 실행합니다.

Ubuntu 또는 Debian 계열의 새 Linux 환경이라면 다음 프로그램을 설치합니다.

```bash
sudo apt update
sudo apt install unzip iproute2 procps
```

- `unzip`(ZIP 압축 파일을 푸는 프로그램)
- `iproute2`(`ss` 등 네트워크 상태 확인 명령을 제공하는 패키지)
- `procps`(`ps`, `top` 등 프로세스 상태 확인 명령을 제공하는 패키지)

### 2. 환경 준비 스크립트 실행

프로젝트 파일이 들어 있는 폴더에서 실행합니다.

```bash
chmod +x scripts/prepare_environment.sh
./scripts/prepare_environment.sh
```

### 3. 환경변수 적용

환경변수를 현재 터미널에 적용합니다.

```bash
source "$HOME/agent-leak-lab/agent.env"
```

### 4. 정상 부팅 확인

검증 스크립트는 프로그램을 잠깐 실행해 `Agent READY`와 PID를 확인한 뒤 자동으로 종료합니다.

```bash
chmod +x scripts/verify_startup.sh
./scripts/verify_startup.sh
```

정상 부팅을 확인한 후 프로그램을 종료하므로 장애 실험까지 진행되지는 않습니다.

### 5. 장애 증거 수집

장애 실험에서 실행 중인 애플리케이션의 PID를 확인한 뒤, 설정 변경 전에는 `before`, 변경 후에는 `after`로 수집합니다. 같은 실험 이름을 사용하면 결과가 한 폴더 아래에 모입니다.

실제 장애 분석 단계에서는 다음과 같이 애플리케이션을 실행하고 PID를 변수에 저장할 수 있습니다.

```bash
"$AGENT_BINARY" >"$AGENT_LOG_DIR/agent.log" 2>&1 &
AGENT_PID=$!
ps -p "$AGENT_PID" -o pid,stat,comm,args
```

```bash
chmod +x scripts/monitor.sh scripts/collect_evidence.sh

EVIDENCE_SAMPLE_COUNT=30 \
  ./scripts/collect_evidence.sh before oom "$AGENT_PID" "$AGENT_LOG_DIR/agent.log"

EVIDENCE_SAMPLE_COUNT=30 \
  ./scripts/collect_evidence.sh after oom "$AGENT_PID" "$AGENT_LOG_DIR/agent.log"
```

`AGENT_PID`에는 관찰할 프로그램의 PID를 넣습니다. 기본 수집 간격은 1초이며 `EVIDENCE_INTERVAL_SECONDS`로, 저장 위치는 `EVIDENCE_ROOT`로 바꿀 수 있습니다. 애플리케이션 로그 파일 이름이 다르면 실제 경로를 마지막 인수로 지정합니다.

시간에 따른 CPU·메모리 수치만 별도로 수집하려면 다음과 같이 실행합니다.

```bash
./scripts/monitor.sh "$AGENT_PID" "$AGENT_HOME/evidence/manual-metrics.tsv" 1 30
```

증거는 기본적으로 `$AGENT_HOME/evidence/<실험 이름>/before-<수집 시각>` 또는 `after-<수집 시각>`에 저장됩니다. 각 결과에는 다음 자료가 포함됩니다.

- `metrics.tsv`: 시간별 CPU, 메모리, 프로세스 상태, 스레드 수
- `process-*.txt`: 수집 시작·종료 시점의 프로세스 상태
- `threads-*.txt`: 수집 시작·종료 시점의 스레드별 상태
- `top-*.txt`: 수집 시작·종료 시점의 `top` 출력
- `settings.txt`: 실험에 사용한 주요 환경변수
- `application-log-tail.txt`: 지정한 애플리케이션 로그의 마지막 200줄
- `metadata.txt`: 수집 시각, 실험 이름, PID, 운영체제 정보

### 6. OOM 실험 및 검증

OOM 실험은 `MEMORY_LIMIT`만 256MB에서 512MB로 변경해 실행합니다. 실행 중 메모리를 실제로 사용하므로 다른 중요한 작업을 저장한 후 일반 사용자 계정에서 실행합니다.

```bash
chmod +x scripts/run_oom_experiment.sh scripts/verify_oom_evidence.sh
./scripts/run_oom_experiment.sh before 256
./scripts/run_oom_experiment.sh after 512
```

각 명령이 출력한 증거 폴더 경로를 사용해 결과를 검증합니다.

```bash
./scripts/verify_oom_evidence.sh \
  evidence/oom/before-<수집 시각> \
  evidence/oom/after-<수집 시각>
```

기본 설정 실험에서 셸이 `Killed`를 표시하고 종료 코드가 137로 기록될 수 있습니다. 애플리케이션 로그에 `Memory limit exceeded`와 `Self-terminating process`가 함께 있다면 Linux OOM Killer가 아니라 애플리케이션의 `MemoryGuard`가 의도적으로 종료한 결과입니다.

512MB 설정에서는 OOM이 재현되지 않은 뒤 CPU 보호 기능처럼 다음 장애가 나타날 수 있습니다. 이 CPU 증거는 OOM 결과와 구분해 별도 CPU 증거 폴더에 저장합니다.

### 7. CPU 실험 및 검증

CPU 실험은 OOM이 먼저 발생하지 않도록 `MEMORY_LIMIT=512`로 고정하고, `CPU_MAX_OCCUPY`만 80%에서 40%로 변경합니다.

```bash
chmod +x scripts/run_cpu_experiment.sh scripts/verify_cpu_evidence.sh
./scripts/run_cpu_experiment.sh before 80
./scripts/run_cpu_experiment.sh after 40
```

각 명령이 출력한 증거 폴더 경로를 사용해 결과를 검증합니다.

```bash
./scripts/verify_cpu_evidence.sh \
  evidence/cpu/before-<수집 시각> \
  evidence/cpu/after-<수집 시각>
```

Before 결과의 종료 코드 143은 CPU 임계치 보호 정책이 보낸 SIGTERM 종료를 의미합니다. After 결과의 SIGTERM은 CPU 임계치 종료가 아니라, 60초 관찰을 마친 실험 스크립트가 살아 있는 프로세스를 정리한 결과입니다.

애플리케이션 내부 `CpuWorker` 값과 Linux `top` 값은 같은 수치가 아닙니다. 내부 값이 실제 시스템 전체 또는 프로세스 CPU 사용률이라고 단정하지 말고, `cpu-worker-load.tsv`와 `top-timeseries.txt`를 함께 확인해야 합니다.

### 8. Deadlock 실험 및 검증

Deadlock 실험은 앞선 장애가 먼저 발생하지 않도록 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`으로 고정하고 `MULTI_THREAD_ENABLE`만 변경합니다.

```bash
chmod +x scripts/run_deadlock_experiment.sh scripts/verify_deadlock_evidence.sh
./scripts/run_deadlock_experiment.sh before true
./scripts/run_deadlock_experiment.sh after false
```

각 명령이 출력한 증거 폴더 경로를 사용해 결과를 검증합니다.

```bash
./scripts/verify_deadlock_evidence.sh \
  evidence/deadlock/before-<수집 시각> \
  evidence/deadlock/after-<수집 시각>
```

Deadlock은 프로세스가 종료되는 장애가 아니므로 두 실험 모두 30초 관찰 후 실행 스크립트가 프로세스를 종료합니다. Before에서는 PID 생존, WAITING/BLOCKED 로그, `futex_wait_queue`, CPU·RSS 정체를 함께 확인합니다.

After에서도 정상 모니터링용 스레드가 남을 수 있으므로 스레드 수만으로 성공 여부를 판단하지 않습니다. `[Scheduler] All tasks completed.`, 상호 WAITING/BLOCKED 로그 부재, 스레드 대기 위치를 함께 확인해야 합니다.

### 9. 장애 리포트 확인

작성된 GitHub Issue 형식 리포트는 다음과 같습니다.

- [OOM Crash 리포트](reports/01-oom-crash.md)
- [CPU Latency/과점유 리포트](reports/02-cpu-latency.md)
- [Deadlock 리포트](reports/03-deadlock.md)

각 리포트에는 번호가 붙은 `Description`, `Evidence & Logs`, `Root Cause Analysis`, `Workaround & Verification` 섹션과 원본 증거 링크가 포함되어 있습니다.

```bash
chmod +x scripts/verify_reports.sh
./scripts/verify_reports.sh
```

검증 명령은 리포트 수, 필수 섹션, Before & After 내용, 장애별 필수 증거와 상대 링크의 실제 파일 존재 여부를 확인합니다.

### 10. 최종 제출 전 확인

다음 검증 명령이 모두 성공한 뒤 변경분을 커밋하고 원격 GitHub 저장소에 푸시합니다. 제출할 저장소 링크는 `https://github.com/bllancck/B4-2.linux-troubleshooting`입니다.

```bash
./scripts/verify_oom_evidence.sh \
  evidence/oom/before-20260913-194113-782307006 \
  evidence/oom/after-20260913-195102-393699520

./scripts/verify_cpu_evidence.sh \
  evidence/cpu/before-20260913-201340-113910967 \
  evidence/cpu/after-20260913-201529-655062996

./scripts/verify_deadlock_evidence.sh \
  evidence/deadlock/before-20260913-203109-415113757 \
  evidence/deadlock/after-20260913-203213-163937858

./scripts/verify_reports.sh
```

CPU Before 증거에서는 애플리케이션 내부 `CpuWorker` 값이 55.11%까지 상승했지만, 같은 PID를 Linux `top`으로 측정한 최댓값은 5%였습니다. 또한 제공 바이너리는 `[WATCHDOG]`라는 이름 대신 `CPU Threshold Violated` 로그와 종료 코드 143(SIGTERM)을 남깁니다. 제출 기준에서 앱 내부 관제값과 이 종료 증거를 인정하는지 먼저 확인해야 합니다. 이 차이는 [CPU 리포트](reports/02-cpu-latency.md)의 원인 분석에 그대로 기록되어 있습니다.

## 구현 내용

- [x] Linux와 일반 사용자 계정인지 확인
- [x] CPU 아키텍처(CPU 명령 처리 방식)에 맞는 x86_64 또는 arm64 바이너리 선택
- [x] 업로드, API key, 로그 디렉터리 생성
- [x] `secret.key` 생성
- [x] 필수 환경변수 파일 생성
- [x] 로그 디렉터리 쓰기 권한과 15034 포트(프로그램이 네트워크 통신에 사용하는 번호가 붙은 통로) 사용 가능 여부 확인
- [x] 애플리케이션 정상 부팅과 PID 확인
- [x] 정상 부팅 로그 저장 후 확인용 프로세스 종료
- [x] CPU·메모리·프로세스·스레드·로그 증거 수집 도구 준비
- [x] OOM 메모리 증가와 `MemoryGuard` 종료 분석
- [x] `MEMORY_LIMIT` 변경 전후 OOM 재현 여부 비교
- [x] 내부 CPU 판정값 상승과 SIGTERM 종료 분석
- [x] `CPU_MAX_OCCUPY` 변경 전후 CPU 임계치 재현 여부 비교
- [x] PID 생존과 스레드 상호 WAITING/BLOCKED 상태 분석
- [x] `MULTI_THREAD_ENABLE` 변경 전후 Deadlock 재현 여부 비교
- [x] OOM, CPU, Deadlock 장애 분석 리포트 3건 작성
- [ ] 사용자 확인 필요: CPU 증거 해석 확인 및 GitHub 푸시 후 제출 링크 점검

자세한 단계는 `implementation_plan.md`에서 확인할 수 있습니다.

## 실행/검증 결과

WSL의 x86_64 환경에서 `scripts/prepare_environment.sh` 실행을 확인했습니다.

```text
환경 준비와 검증이 완료되었습니다.
선택된 아키텍처: x86_64
선택된 바이너리: agent-leak-app-x86
AGENT_HOME: /home/byj/agent-leak-lab
```

환경 파일과 키 파일 생성, 바이너리 실행 권한, 로그 디렉터리 쓰기 권한, 15034 포트 사용 가능 여부까지 확인했습니다.

이후 장애를 부팅 실패와 구분하기 위해 `verify_startup.sh`로 정상 실행 기준을 확인했습니다.
실행 중 `Agent READY`와 PID를 확인했으며, 검증 후 프로세스 종료와 15034 포트 해제도 확인했습니다.
시작 로그는 `/home/byj/agent-leak-lab/logs/startup-verification.log`에 저장됩니다. 이 정상 부팅 검사는 장애를 발생시키지 않고 시작 가능 여부만 확인합니다.

증거 수집 스크립트는 WSL의 실행 중인 프로세스를 대상으로 검증했습니다. `before`와 `after` 폴더에 시간별 CPU·메모리 수치, 프로세스 및 스레드 상태, `top` 출력, 설정값, 애플리케이션 로그가 각각 저장되는 것을 확인했습니다.

OOM 기본 실험에서는 `MEMORY_LIMIT=256`일 때 RSS가 18,048KiB에서 최대 274,048KiB로 증가했습니다. 애플리케이션 Heap은 275MB까지 증가했고 `275MB >= 256MB`에서 `MemoryGuard`가 프로세스를 종료했습니다. 종료까지 걸린 시간은 35초였습니다.

`MEMORY_LIMIT=512`로 변경한 실험에서는 RSS가 18,048KiB로 유지됐고 `MemoryWorker`와 메모리 제한 초과 로그가 나타나지 않았습니다. 이후 CPU 보호 기능이 별도로 동작했으므로 전체 프로그램이 안정화된 것은 아닙니다. 자세한 근거와 제약은 `evidence/oom/analysis-summary.md`에 정리되어 있습니다.

CPU 기본 실험에서는 `CPU_MAX_OCCUPY=80`일 때 애플리케이션 내부 `CpuWorker` 판정값이 5.00%에서 55.11%까지 증가했고, `CPU Threshold Violated` 후 SIGTERM으로 종료됐습니다. 반복 수집한 `top`의 해당 프로세스 최대값은 5%여서 내부 판정값과 OS 관제값은 일치하지 않았습니다.

`CPU_MAX_OCCUPY=40`으로 변경한 실험에서는 60초 동안 `CpuWorker`와 CPU 임계치 종료가 나타나지 않았고 프로세스가 계속 살아 있었습니다. 자세한 근거와 주의사항은 `evidence/cpu/analysis-summary.md`에 정리되어 있습니다.

Deadlock 기본 실험에서는 두 작업 스레드가 각각 `Shared_Memory_A`와 `Socket_Pool_B`를 보유한 채 상대 자원을 기다렸습니다. PID는 30초 후에도 살아 있었지만 세 스레드가 모두 `futex_wait_queue`에 있었고, CPU는 9.5%에서 0.4%로 낮아졌으며 RSS 변화는 128KiB에 그쳤습니다.

`MULTI_THREAD_ENABLE=false`로 변경하면 상호 WAITING/BLOCKED 로그가 사라지고 `[Scheduler] All tasks completed.`가 기록됐습니다. 정상 모니터링 작업으로 RSS 증가와 세 개의 스레드는 계속 관찰됐지만, 이는 Deadlock 재발과 구분했습니다. 자세한 근거는 `evidence/deadlock/analysis-summary.md`에 정리되어 있습니다.

세 장애의 결과는 `reports/` 아래 GitHub Issue 형식 문서로 정리했습니다. 자동 검증에서 리포트 3건의 필수 섹션, Before & After 비교, 장애별 핵심 내용과 모든 증거 링크가 유효한 것을 확인했습니다.

## 트러블슈팅

### `unzip` 또는 `ss` 명령을 찾을 수 없는 경우

```bash
sudo apt update
sudo apt install unzip iproute2
```

### root 계정 오류가 발생하는 경우

`root가 아닌 일반 사용자 계정으로 실행하세요.`라는 메시지가 나오면 일반 사용자로 로그인한 터미널에서 스크립트를 다시 실행합니다.

### 15034 포트가 이미 사용 중인 경우

다음 명령으로 15034 포트를 사용하는 프로그램이 있는지 확인합니다.

```bash
ss -ltnp | grep ':15034'
```

기존 프로그램을 종료하거나 15034 포트를 비운 후 준비 스크립트를 다시 실행합니다.

### `Agent READY`를 확인하지 못한 경우

다음 로그 파일에서 부팅 검사가 실패한 위치를 확인합니다.

```bash
cat "$HOME/agent-leak-lab/logs/startup-verification.log"
```
