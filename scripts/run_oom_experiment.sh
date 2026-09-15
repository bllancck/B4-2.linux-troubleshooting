#!/usr/bin/env bash

set -euo pipefail

export COLUMNS=120
export LINES=40

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
사용법: run_oom_experiment.sh <before|after> <MEMORY_LIMIT>

예시:
  ./scripts/run_oom_experiment.sh before 256
  ./scripts/run_oom_experiment.sh after 512

선택 환경변수:
  OOM_SAMPLE_COUNT      최대 관제 횟수(기본값: 120)
  OOM_INTERVAL_SECONDS  관제 간격(기본값: 1)
  EVIDENCE_ROOT         증거 저장 폴더(기본값: <프로젝트>/evidence)
EOF
}

process_exists() {
  ps -p "$1" -o pid= 2>/dev/null | grep -Eq '[0-9]'
}

stop_process() {
  local pid="$1"

  if [[ -n "$pid" ]] && process_exists "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true

    for _ in 1 2 3 4 5; do
      process_exists "$pid" || break
      sleep 0.2
    done

    if process_exists "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

stop_agent() {
  stop_process "${monitored_pid:-}"

  if [[ "${launcher_pid:-}" != "${monitored_pid:-}" ]]; then
    stop_process "${launcher_pid:-}"
  fi

  if [[ -n "${launcher_pid:-}" ]]; then
    wait "$launcher_pid" 2>/dev/null || true
  fi
}

find_worker_pid() {
  local launcher="$1"
  local child_pid

  child_pid="$(LC_ALL=C ps --ppid "$launcher" -o pid=,rss= --sort=-rss 2>/dev/null | awk 'NR == 1 {print $1}' || true)"

  if [[ -n "$child_pid" ]] && process_exists "$child_pid"; then
    printf '%s\n' "$child_pid"
  else
    printf '%s\n' "$launcher"
  fi
}

remove_temporary_files() {
  if [[ -n "${run_environment_file:-}" && -f "$run_environment_file" ]]; then
    rm -f -- "$run_environment_file"
  fi

  if [[ -n "${output_path_file:-}" && -f "$output_path_file" ]]; then
    rm -f -- "$output_path_file"
  fi
}

cleanup() {
  stop_agent
  remove_temporary_files
}

port_is_available() {
  ! ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:|\])15034$'
}

main() {
  if (($# != 2)); then
    usage >&2
    exit 2
  fi

  local phase="$1"
  local memory_limit="$2"
  local configured_agent_home
  local environment_file
  local script_dir
  local project_dir
  local evidence_root
  local sample_count
  local interval_seconds
  local ready=false
  local start_epoch
  local end_epoch
  local duration_seconds
  local exit_code
  local run_log
  local output_dir
  local launcher_pid
  local monitored_pid
  local stopped_after_observation=false
  local oom_observed=false
  local termination_reason

  [[ "$(uname -s)" == 'Linux' ]] || fail '이 스크립트는 Linux 환경에서만 실행할 수 있습니다.'
  [[ "$(id -u)" -ne 0 ]] || fail 'root가 아닌 일반 사용자 계정으로 실행하세요.'
  [[ "$phase" == 'before' || "$phase" == 'after' ]] || fail '첫 번째 인수는 before 또는 after여야 합니다.'
  [[ "$memory_limit" =~ ^[0-9]+$ ]] || fail 'MEMORY_LIMIT는 정수여야 합니다.'
  ((memory_limit >= 50 && memory_limit <= 512)) || fail 'MEMORY_LIMIT는 50~512 사이여야 합니다.'

  command -v ss >/dev/null 2>&1 || fail "'ss' 명령을 찾을 수 없습니다."
  command -v mktemp >/dev/null 2>&1 || fail "'mktemp' 명령을 찾을 수 없습니다."

  configured_agent_home="${AGENT_HOME:-$HOME/agent-leak-lab}"
  environment_file="${AGENT_ENV_FILE:-$configured_agent_home/agent.env}"
  [[ -f "$environment_file" ]] || fail "환경 파일이 없습니다: $environment_file. 다른 계정의 AGENT_HOME이 남아 있는지 확인하고 prepare_environment.sh를 다시 실행하세요."

  # shellcheck disable=SC1090
  source "$environment_file"

  [[ -x "$AGENT_BINARY" ]] || fail "바이너리를 실행할 수 없습니다: $AGENT_BINARY"
  [[ -d "$AGENT_LOG_DIR" && -w "$AGENT_LOG_DIR" ]] || fail "로그 디렉터리에 쓸 수 없습니다: $AGENT_LOG_DIR"
  [[ "$AGENT_PORT" == '15034' ]] || fail 'AGENT_PORT는 15034여야 합니다.'
  port_is_available || fail '0.0.0.0:15034 포트가 이미 사용 중입니다.'

  sample_count="${OOM_SAMPLE_COUNT:-120}"
  interval_seconds="${OOM_INTERVAL_SECONDS:-1}"
  [[ "$sample_count" =~ ^[1-9][0-9]*$ ]] || fail 'OOM_SAMPLE_COUNT는 1 이상의 정수여야 합니다.'
  [[ "$interval_seconds" =~ ^[1-9][0-9]*$ ]] || fail 'OOM_INTERVAL_SECONDS는 1 이상의 정수여야 합니다.'

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  project_dir="$(cd -- "$script_dir/.." && pwd)"
  evidence_root="${EVIDENCE_ROOT:-$project_dir/evidence}"
  mkdir -p "$evidence_root" "$AGENT_LOG_DIR"

  run_environment_file="$(mktemp "$AGENT_HOME/oom-experiment.XXXXXX.env")"
  output_path_file="$(mktemp "$AGENT_HOME/oom-output-path.XXXXXX.txt")"
  run_log="$AGENT_LOG_DIR/oom-$phase-memory-limit-$memory_limit.log"
  trap cleanup EXIT INT TERM

  {
    printf 'export AGENT_HOME=%q\n' "$AGENT_HOME"
    printf 'export AGENT_PORT=%q\n' "$AGENT_PORT"
    printf 'export AGENT_UPLOAD_DIR=%q\n' "$AGENT_UPLOAD_DIR"
    printf 'export AGENT_KEY_PATH=%q\n' "$AGENT_KEY_PATH"
    printf 'export AGENT_LOG_DIR=%q\n' "$AGENT_LOG_DIR"
    printf 'export MEMORY_LIMIT=%q\n' "$memory_limit"
    printf 'export CPU_MAX_OCCUPY=%q\n' "$CPU_MAX_OCCUPY"
    printf 'export MULTI_THREAD_ENABLE=%q\n' "$MULTI_THREAD_ENABLE"
    printf 'export AGENT_BINARY=%q\n' "$AGENT_BINARY"
  } >"$run_environment_file"
  chmod 0600 "$run_environment_file"

  : >"$run_log"
  start_epoch="$(date +%s)"
  MEMORY_LIMIT="$memory_limit" "$AGENT_BINARY" >"$run_log" 2>&1 &
  launcher_pid=$!
  monitored_pid=''

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -Fq 'Agent READY' "$run_log"; then
      ready=true
      break
    fi

    process_exists "$launcher_pid" || break
    sleep 1
  done

  if [[ "$ready" != true ]]; then
    printf '%s\n' '--- 실행 로그 ---'
    cat "$run_log"
    fail "10초 안에 'Agent READY'를 확인하지 못했습니다."
  fi

  monitored_pid="$(find_worker_pid "$launcher_pid")"
  process_exists "$monitored_pid" || fail "관찰할 작업 프로세스를 찾지 못했습니다. 실행 PID: $launcher_pid"

  AGENT_ENV_FILE="$run_environment_file" \
    EVIDENCE_ROOT="$evidence_root" \
    EVIDENCE_INTERVAL_SECONDS="$interval_seconds" \
    EVIDENCE_SAMPLE_COUNT="$sample_count" \
    EVIDENCE_OUTPUT_PATH_FILE="$output_path_file" \
    "$script_dir/collect_evidence.sh" "$phase" oom "$monitored_pid" "$run_log"

  output_dir="$(<"$output_path_file")"

  if process_exists "$monitored_pid"; then
    if [[ "$phase" == 'before' ]]; then
      fail "$sample_count회 관제하는 동안 OOM 종료가 발생하지 않았습니다. 표본 수를 늘려 다시 실행하세요."
    fi

    stopped_after_observation=true
    stop_process "$monitored_pid"

    if [[ "$launcher_pid" != "$monitored_pid" ]]; then
      stop_process "$launcher_pid"
    fi
  fi

  set +e
  wait "$launcher_pid"
  exit_code=$?
  set -e
  launcher_pid=''
  monitored_pid=''

  end_epoch="$(date +%s)"
  duration_seconds=$((end_epoch - start_epoch))

  if grep -Fqi 'Memory limit exceeded' "$run_log"; then
    oom_observed=true
    termination_reason='Memory limit exceeded / SELF-TERMINATED'
  elif grep -Fqi 'CPU Threshold Violated' "$run_log"; then
    termination_reason='CPU Threshold Violated (OOM not observed)'
  elif [[ "$stopped_after_observation" == true ]]; then
    termination_reason='Observation completed without OOM; process stopped by experiment script'
  else
    termination_reason='Process exited without MemoryGuard termination'
  fi

  if [[ "$phase" == 'before' ]]; then
    [[ "$oom_observed" == true ]] || fail "기본 설정에서 'Memory limit exceeded'를 찾지 못했습니다."
    grep -Eqi 'SELF-TERMINATED|Self-terminating process' "$run_log" || fail '로그에서 자기 종료 메시지를 찾지 못했습니다.'
  else
    [[ "$oom_observed" == false ]] || fail '변경 설정에서도 MemoryGuard에 의한 OOM 종료가 발생했습니다.'
  fi

  {
    printf 'phase=%s\n' "$phase"
    printf 'memory_limit=%s\n' "$memory_limit"
    printf 'duration_seconds=%s\n' "$duration_seconds"
    printf 'process_exit_code=%s\n' "$exit_code"
    printf 'oom_observed=%s\n' "$oom_observed"
    printf 'termination_reason=%s\n' "$termination_reason"
  } >"$output_dir/run-summary.txt"

  cp -- "$run_log" "$output_dir/application-full.log"

  remove_temporary_files
  trap - EXIT INT TERM

  printf '\nOOM 실험 완료\n'
  printf 'MEMORY_LIMIT: %s\n' "$memory_limit"
  printf '종료까지 걸린 시간: %s초\n' "$duration_seconds"
  printf '프로세스 종료 코드: %s\n' "$exit_code"
  printf 'OOM 관찰 여부: %s\n' "$oom_observed"
  printf '종료/관찰 결과: %s\n' "$termination_reason"
  printf '증거 저장 위치: %s\n' "$output_dir"
}

main "$@"
