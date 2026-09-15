# Linux 시스템 장애 분석

## 프로젝트 목적

애플리케이션 장애를 로그로 분석하고 해결하는 과정을 연습하는 프로젝트입니다.

Linux 환경에서 `agent-leak-app`을 실행해 OOM, CPU 과점유, Deadlock을 의도적으로 재현한 뒤, 원인을 파악하고 설정값을 변경해 해결 여부를 검증합니다.

## 트러블슈팅

### 한눈에 보기

| 장애 | 문제 상황 | 변경 | 결과 | 원인 |
| --- | --- | --- | --- | --- |
| **OOM** | Heap이 계속 증가해 프로그램 종료 | `MEMORY_LIMIT` `256 → 512` | 메모리 초과 종료 미발생 | 프로그램 내부 메모리 제한 초과 |
| **CPU 과점유** | 내부 CPU 기준 초과로 프로그램 종료 | `CPU_MAX_OCCUPY` `80 → 40` | CPU 보호 종료 없이 실행 유지 | 애플리케이션 내부 CPU 기준 초과 |
| **Deadlock** | 프로세스는 살아 있지만 스레드가 서로 기다려 작업이 멈춤 | `MULTI_THREAD_ENABLE` `true → false` | 작업을 순서대로 처리해 완료 | 두 스레드가 서로의 자원을 기다림 |

<a id="1-oom"></a>

### 1. OOM

**Before:** `MEMORY_LIMIT=256`으로 테스트한 결과, `MemoryWorker`가 메모리를 계속 누적하면서 Heap과 RSS가 증가했습니다.

```text
Heap 증가: 225MB → 250MB → 275MB
RSS 증가:  18,048KiB → 274,048KiB
제한 초과: 275MB >= 256MB
결과:      MemoryGuard가 프로세스를 자체 종료(137)
```

**After:** `MEMORY_LIMIT=512`로 변경한 뒤에는 메모리 제한 초과와 `MemoryGuard` 종료가 발생하지 않았습니다.

> **판단:** 이번 종료의 원인은 Linux OOM Killer가 아니라 `MemoryWorker`의 메모리 누적으로 내부 메모리 제한을 초과한 `MemoryGuard`였습니다.

[상세 리포트](reports/01-oom-crash.md)

<a id="2-cpu-과점유"></a>

### 2. CPU 과점유

**Before:** `CPU_MAX_OCCUPY=80`에서 애플리케이션 내부 `CpuWorker` 값이 상승하다가 `CPU Threshold Violated` 로그와 SIGTERM이 발생했습니다.

| 측정 대상 | 관찰 결과 |
| --- | --- |
| 애플리케이션 내부 값 | `5.00% → 55.11%`로 상승 후 임계치 초과 |
| Linux `top` | 같은 구간의 최댓값 약 `5%` |

이 실험에서 확인하려는 핵심은 Linux의 실제 CPU 사용률 자체가 아니라, 애플리케이션이 내부 기준을 넘었다고 판단해 보호 종료하는 동작입니다.

**After:** `MEMORY_LIMIT=512`를 유지하고 `CPU_MAX_OCCUPY`를 `40`으로 낮춘 After 설정에서는 CPU 임계치 초과와 보호 종료가 발생하지 않았습니다.

> **판단:** 이 장애는 실제 Linux CPU 과점유가 아니라, `CPU_MAX_OCCUPY=80`에서 내부 부하 판정값이 안전 기준을 넘어 발생한 애플리케이션의 보호 종료입니다.

[상세 리포트](reports/02-cpu-latency.md)

<a id="3-deadlock"></a>

### 3. Deadlock

**Before:** `MULTI_THREAD_ENABLE=true`에서 두 작업 스레드가 자원을 하나씩 보유한 채 서로가 가진 자원을 기다렸습니다.

```text
스레드 A: Shared_Memory_A 보유 → Socket_Pool_B 대기
스레드 B: Socket_Pool_B 보유   → Shared_Memory_A 대기
```

[애플리케이션 로그](evidence/deadlock/before-20260913-203109-415113757/application-full.log)가 두 작업 스레드의 `WAITING/BLOCKED`에서 멈춘 뒤 약 22초 동안 새 작업 로그와 완료 메시지를 남기지 않아 작업 정체를 감지했습니다. 프로세스 종료 여부를 확인한 결과, 30초 관찰 후에도 [실행 요약](evidence/deadlock/before-20260913-203109-415113757/run-summary.txt)에 `process_alive_after_observation=true`가 기록됐고 [최종 프로세스 상태](evidence/deadlock/before-20260913-203109-415113757/process-final.txt)에도 PID `16535`가 남아 있었습니다. 이어 [스레드 대기 위치](evidence/deadlock/before-20260913-203109-415113757/thread-wait-channels.txt)를 확인하자 스레드들이 `futex_wait_queue`에서 대기 중이었습니다.

[애플리케이션 로그와 linux 명령어로 Deadlock을 확인한 과정](docs/deadlock-observation-guide.md)

**After:** `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=40`을 유지하고 `MULTI_THREAD_ENABLE=false`로 변경했습니다. 멀티스레드 동시 처리를 끄자 작업이 서로 자원을 기다리지 않고 순서대로 처리됐으며, 마지막에 `[Scheduler] All tasks completed.`가 기록됐습니다.

> **판단:** PID가 살아 있는데도 두 스레드가 `futex_wait_queue`에서 멈췄으므로, 이 현상은 단순한 처리 지연이 아니라 교차 잠금에 의한 Deadlock으로 판단했습니다.

[상세 리포트](reports/03-deadlock.md)

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
├── evidence/                       # 장애별 로그와 관제 데이터 등 원본 증거
└── reports/                        # 원본 증거를 분석한 GitHub Issue 형식 상세 리포트
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
