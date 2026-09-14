# Linux 시스템 장애 분석

## 프로젝트 목적

제공된 `agent-leak-app`을 Linux 환경에서 실행해 OOM, CPU 과점유, Deadlock을 재현·분석하는 프로젝트입니다.

로그와 시스템 지표로 장애 원인을 규명하고, 설정 변경 전후를 비교해 조치 효과를 검증합니다. 수집한 증거와 분석 결과는 GitHub Issue 형식의 리포트로 정리했습니다.

## 트러블슈팅

### 한눈에 보기

- **OOM**: `MemoryGuard` 종료 → 메모리 제한 상향 → OOM 미발생
- **CPU 과점유**: 내부 부하 임계치 초과 → CPU 설정 하향 → 보호 종료 미발생
- **Deadlock**: 작업 스레드 순환 대기 → 멀티스레드 비활성화 → 작업 완료

<a id="1-oom"></a>

### 1. OOM

#### 문제 상황

`MEMORY_LIMIT=256`에서 RSS가 18,048KiB에서 274,048KiB까지 증가했습니다. Heap이 275MB에 도달하자 `MemoryGuard` 로그와 함께 프로세스가 종료 코드 137로 종료됐습니다.

#### 조치와 결과

`MEMORY_LIMIT`를 512MB로 높이자 메모리 제한 초과 로그와 종료가 발생하지 않았습니다.

#### 분석 결론

종료 원인은 Linux OOM Killer가 아니라 애플리케이션의 내부 메모리 제한이었습니다. OOM을 제거한 뒤 나타난 CPU 장애는 별도 문제로 분리해 분석했습니다.

[상세 리포트](reports/01-oom-crash.md) · [증거 요약](evidence/oom/analysis-summary.md)

<a id="2-cpu-과점유"></a>

### 2. CPU 과점유

#### 문제 상황

`CPU_MAX_OCCUPY=80`에서 내부 `CpuWorker` 값이 5.00%에서 55.11%까지 상승한 뒤 `CPU Threshold Violated` 로그와 SIGTERM이 발생했습니다. 같은 구간의 Linux `top` 최댓값은 5%였습니다.

#### 조치와 결과

`MEMORY_LIMIT=512`로 고정하고 `CPU_MAX_OCCUPY`를 40%로 낮추자 60초 동안 CPU 임계치가 발생하지 않았고 프로세스가 유지됐습니다.

#### 분석 결론

실제 Linux CPU 포화가 아니라 애플리케이션 내부 판정값에 따른 보호 종료였습니다. After의 SIGTERM은 장애가 아니라 관찰을 마친 실험 스크립트의 정리 동작입니다.

[상세 리포트](reports/02-cpu-latency.md) · [증거 요약](evidence/cpu/analysis-summary.md)

<a id="3-deadlock"></a>

### 3. Deadlock

#### 문제 상황

`MULTI_THREAD_ENABLE=true`에서 두 작업 스레드가 각각 `Shared_Memory_A`와 `Socket_Pool_B`를 보유한 채 상대 자원을 기다렸습니다. 프로세스는 살아 있었지만 작업은 완료되지 않았고, 세 스레드가 모두 `futex_wait_queue`에서 대기했습니다.

#### 조치와 결과

`MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`으로 고정하고 `MULTI_THREAD_ENABLE=false`로 바꾸자 상호 대기 로그가 사라지고 `[Scheduler] All tasks completed.`가 기록됐습니다.

#### 분석 결론

Deadlock은 프로세스 생존 여부나 스레드 수만으로 판단할 수 없습니다. 작업 완료 로그와 스레드 대기 상태를 함께 확인해야 합니다.

[상세 리포트](reports/03-deadlock.md) · [증거 요약](evidence/deadlock/analysis-summary.md)

## 실행 환경

- Linux 또는 WSL
- Bash
- x86_64/amd64 또는 arm64/aarch64 CPU
- `unzip`, `iproute2`, `procps` 패키지
- root가 아닌 일반 사용자 계정

실험은 WSL의 x86_64 환경에서 검증했습니다. `prepare_environment.sh`가 CPU 아키텍처에 맞는 바이너리를 자동으로 선택합니다.

## 제약 사항

- 애플리케이션은 고정 포트 `15034`를 사용하므로 실행 전에 포트가 비어 있어야 합니다.
- `AGENT_HOME`은 절대 경로여야 하며, 로그와 증거를 저장할 쓰기 권한이 필요합니다.
- `MEMORY_LIMIT`는 50~512 사이, `CPU_MAX_OCCUPY`는 10~100 사이의 정수만 허용합니다.
- `MULTI_THREAD_ENABLE`은 `true/false`, `1/0`, `yes/no` 중 하나여야 합니다.
- OOM 실험은 실제 메모리를 사용하므로 중요한 작업을 저장한 뒤 실행합니다.
- 장애 간 영향을 분리하기 위해 CPU 실험은 `MEMORY_LIMIT=512`, Deadlock 실험은 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`으로 고정합니다.

## 환경변수 설정

`prepare_environment.sh`는 다음 기본값으로 `$AGENT_HOME/agent.env`를 생성합니다.

```bash
AGENT_HOME=$HOME/agent-leak-lab
AGENT_PORT=15034
AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
AGENT_KEY_PATH=$AGENT_HOME/api_keys
AGENT_LOG_DIR=$AGENT_HOME/logs
AGENT_BINARY=$AGENT_HOME/bin/agent-leak-app

MEMORY_LIMIT=256
CPU_MAX_OCCUPY=80
MULTI_THREAD_ENABLE=true
```

기본값을 바꾸려면 환경 준비 스크립트를 실행할 때 값을 전달합니다. `AGENT_HOME`은 절대 경로로 지정합니다.

```bash
export AGENT_HOME=/home/user/agent-leak-lab
export MEMORY_LIMIT=256
export CPU_MAX_OCCUPY=80
export MULTI_THREAD_ENABLE=true

./scripts/prepare_environment.sh
```

생성된 설정은 `source "$AGENT_HOME/agent.env"`로 현재 셸에 적용합니다.

## 실행 방법

### 1. 환경 준비

```bash
sudo apt update
sudo apt install unzip iproute2 procps

ss -ltnp | grep ':15034'

chmod +x scripts/*.sh
./scripts/prepare_environment.sh
source "$HOME/agent-leak-lab/agent.env"
./scripts/verify_startup.sh
```

15034 포트를 사용 중인 프로세스가 있다면 종료한 뒤 다시 실행합니다. `sudo`는 패키지 설치에만 사용합니다.

### 2. 장애 재현

```bash
./scripts/run_oom_experiment.sh before 256
./scripts/run_oom_experiment.sh after 512

./scripts/run_cpu_experiment.sh before 80
./scripts/run_cpu_experiment.sh after 40

./scripts/run_deadlock_experiment.sh before true
./scripts/run_deadlock_experiment.sh after false
```

실험 결과는 `evidence/<장애 유형>/before-<수집 시각>`과 `after-<수집 시각>`에 저장됩니다.

### 3. 결과 검증

각 실험 명령이 출력한 증거 폴더 경로를 지정합니다.

```bash
./scripts/verify_oom_evidence.sh \
  evidence/oom/before-<수집 시각> \
  evidence/oom/after-<수집 시각>

./scripts/verify_cpu_evidence.sh \
  evidence/cpu/before-<수집 시각> \
  evidence/cpu/after-<수집 시각>

./scripts/verify_deadlock_evidence.sh \
  evidence/deadlock/before-<수집 시각> \
  evidence/deadlock/after-<수집 시각>

./scripts/verify_reports.sh
```

## 프로젝트 구조

```text
.
├── agent-app-leak.zip              # 제공된 실행 파일 압축본
├── scripts/
│   ├── prepare_environment.sh      # Linux 실행 환경 준비 및 검증
│   ├── verify_startup.sh           # 정상 부팅과 PID 확인
│   ├── monitor.sh                  # CPU·메모리 변화 수집
│   ├── collect_evidence.sh         # 장애 증거 수집
│   ├── run_oom_experiment.sh       # OOM Before & After 실험
│   ├── verify_oom_evidence.sh      # OOM 증거 검증
│   ├── run_cpu_experiment.sh       # CPU Before & After 실험
│   ├── verify_cpu_evidence.sh      # CPU 증거 검증
│   ├── run_deadlock_experiment.sh  # Deadlock Before & After 실험
│   ├── verify_deadlock_evidence.sh # Deadlock 증거 검증
│   └── verify_reports.sh           # 리포트와 증거 링크 검증
├── evidence/                       # 장애별 원본 증거와 분석 요약
└── reports/                        # GitHub Issue 형식 장애 리포트
```

## 구현 내용

- [x] 일반 사용자 권한과 CPU 아키텍처 확인
- [x] 필수 패키지, 환경변수, 키, 로그 디렉터리 준비
- [x] 15034 포트와 애플리케이션 정상 부팅 확인
- [x] CPU·메모리·프로세스·스레드·로그 증거 수집
- [x] `MEMORY_LIMIT` 변경 전후 OOM 분석
- [x] `CPU_MAX_OCCUPY` 변경 전후 CPU 임계치 분석
- [x] `MULTI_THREAD_ENABLE` 변경 전후 Deadlock 분석
- [x] 장애 리포트 작성과 증거 링크 검증
