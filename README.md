# Linux 시스템 장애 분석

## 프로젝트 목적

제공된 `agent-leak-app`을 Linux 환경에서 실행해 OOM, CPU 과점유, Deadlock을 재현·분석하는 프로젝트입니다.

로그와 시스템 지표로 장애 원인을 규명하고, 설정 변경 전후를 비교해 조치 효과를 검증합니다. 수집한 증거와 분석 결과는 GitHub Issue 형식의 리포트로 정리했습니다.

## 트러블슈팅

### 한눈에 보기

| 장애 | 문제 상황 | 변경 | 결과 | 분석 결론 |
| --- | --- | --- | --- | --- |
| [OOM](#1-oom) | Heap 증가 후 `MemoryGuard` 종료(137) | `MEMORY_LIMIT` 256 → 512 | 메모리 제한 초과 미발생 | Linux OOM Killer가 아닌 내부 보호 종료 |
| [CPU 과점유](#2-cpu-과점유) | 내부 부하 임계치 초과 후 SIGTERM | `CPU_MAX_OCCUPY` 80 → 40 | 60초 동안 보호 종료 미발생 | 실제 CPU 포화가 아닌 내부 판정값 문제 |
| [Deadlock](#3-deadlock) | 두 작업 스레드의 순환 대기 | `MULTI_THREAD_ENABLE` true → false | 상호 대기 해소 및 작업 완료 | 프로세스 생존보다 작업·대기 상태 확인 필요 |

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

- 운영체제: Linux 또는 WSL
- 지원 아키텍처: x86_64/amd64, arm64/aarch64
- 셸: Bash
- 필수 패키지: `unzip`, `iproute2`, `procps`
- 검증 환경: WSL x86_64

## 제약 사항

- root 계정 실행 불가
- 고정 포트 `15034` 사용
- `AGENT_HOME`의 절대 경로와 쓰기 권한 필요
- OOM 실험의 실제 메모리 사용

## 환경변수 설정

### 장애 재현 설정

| 환경변수 | 기본값 | 허용값 | 용도 |
| --- | --- | --- | --- |
| `MEMORY_LIMIT` | `256` | 50~512 사이의 정수 | 메모리 제한 설정 |
| `CPU_MAX_OCCUPY` | `80` | 10~100 사이의 정수 | CPU 부하 설정 |
| `MULTI_THREAD_ENABLE` | `true` | `true/false`, `1/0`, `yes/no` | 멀티스레드 활성화 |

### 경로 및 실행 설정

| 환경변수 | 기본값 | 용도 |
| --- | --- | --- |
| `AGENT_HOME` | `$HOME/agent-leak-lab` | 작업 기준 경로 |
| `AGENT_PORT` | `15034` | 애플리케이션 고정 포트 |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files` | 업로드 파일 저장 경로 |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys` | `secret.key` 저장 경로 |
| `AGENT_LOG_DIR` | `$AGENT_HOME/logs` | 로그 저장 경로 |
| `AGENT_BINARY` | `$AGENT_HOME/bin/agent-leak-app` | 아키텍처별 실행 파일 경로 |

## 실행 방법

### 1. 필수 패키지 설치

```bash
# sudo는 패키지 설치에만 사용
sudo apt update
sudo apt install unzip iproute2 procps
```

### 2. 환경변수 적용 및 부팅 확인

```bash
chmod +x scripts/*.sh
./scripts/prepare_environment.sh
source "${AGENT_HOME:-$HOME/agent-leak-lab}/agent.env"
./scripts/verify_startup.sh
```

- [`prepare_environment.sh`](scripts/prepare_environment.sh): 애플리케이션 실행에 필요한 환경을 자동으로 구성하는 스크립트
  - Linux와 일반 사용자 계정 여부, CPU 아키텍처, 15034 포트 사용 가능 여부 확인
  - 작업 디렉터리와 `secret.key` 생성, 아키텍처에 맞는 바이너리 설치, `agent.env` 작성
- [`verify_startup.sh`](scripts/verify_startup.sh): 준비된 환경에서 애플리케이션이 정상적으로 시작되는지 확인하는 스크립트
  - `agent.env`를 불러와 애플리케이션을 실행하고 `Agent READY` 로그와 PID 확인
  - 시작 로그를 저장한 뒤 장애 실험과 겹치지 않도록 검증용 프로세스 종료

#### 참고용 확인 명령어

```bash
# 15034 포트 점유 확인
ss -ltnp | grep ':15034'

# 실행 중인 애플리케이션의 PID 확인
pgrep -af 'agent-leak-app'

# 확인한 PID의 상태 조회
ps -p <PID> -o pid,stat,comm,args
```

### 3. 장애 재현

```bash
./scripts/run_oom_experiment.sh before 256
./scripts/run_oom_experiment.sh after 512

./scripts/run_cpu_experiment.sh before 80
./scripts/run_cpu_experiment.sh after 40

./scripts/run_deadlock_experiment.sh before true
./scripts/run_deadlock_experiment.sh after false
```

전달받은 설정값으로 Agent를 실행하고 장애별 상태를 수집합니다.

**스크립트별 역할**

- [`run_oom_experiment.sh`](scripts/run_oom_experiment.sh): [`collect_evidence.sh`](scripts/collect_evidence.sh)로 메모리와 로그를 수집하고 `MemoryGuard`의 종료 여부 확인
- [`run_cpu_experiment.sh`](scripts/run_cpu_experiment.sh): `top`으로 CPU 사용률을 수집하고 임계치 초과 및 SIGTERM 여부 확인
- [`run_deadlock_experiment.sh`](scripts/run_deadlock_experiment.sh): `ps -L`과 `top -H`로 스레드 상태를 수집하고 교착 상태 확인

**인수 전달 방식**

Linux 셸은 스크립트 이름 뒤에 공백으로 입력한 값을 왼쪽부터 `$1`, `$2`로 전달합니다. 이 프로젝트에서는 다음과 같이 사용합니다.

- `$1`: 실험 구분(`before` 또는 `after`)
- `$2`: 적용할 설정값

예를 들어 `run_oom_experiment.sh before 256`을 실행하면 스크립트 내부에서 `before`는 `$1`, `256`은 `$2`로 인식됩니다.

**결과 저장 위치**

`evidence/<장애 유형>/<before|after>-<수집 시각>`

### 4. 결과 검증

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
`before`와 `after` 증거 폴더를 차례로 전달받아 설정 변경 전후의 결과를 비교합니다.

**스크립트별 검증 항목**

| 스크립트 | 검증 내용 |
|---|---|
| [`verify_oom_evidence.sh`](scripts/verify_oom_evidence.sh) | 메모리 사용량 증가와 `before`의 강제 종료, `after`의 OOM 미발생 확인 |
| [`verify_cpu_evidence.sh`](scripts/verify_cpu_evidence.sh) | `before`의 CPU 임계치 초과와 SIGTERM 종료, `after`의 정상 생존 확인 |
| [`verify_deadlock_evidence.sh`](scripts/verify_deadlock_evidence.sh) | `before`의 스레드 교착 상태와 `after`의 작업 완료 확인 |
| [`verify_reports.sh`](scripts/verify_reports.sh) | 세 장애 리포트의 필수 항목, Before·After 비교 및 증거 파일 링크 확인 |

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
