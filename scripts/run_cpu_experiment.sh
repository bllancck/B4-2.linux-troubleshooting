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
사용법: run_cpu_experiment.sh <before|after> <CPU_MAX_OCCUPY>

예시:
  ./scripts/run_cpu_experiment.sh before 80
  ./scripts/run_cpu_experiment.sh after 40

선택 환경변수:
  CPU_SAMPLE_COUNT      최대 관제 횟수(기본값: 60)
  CPU_INTERVAL_SECONDS  관제 간격(기본값: 1)
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

stop_top() {
  if [[ -n "${top_pid:-}" ]] && process_exists "$top_pid"; then
    kill -TERM "$top_pid" 2>/dev/null || true
    wait "$top_pid" 2>/dev/null || true
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
  local temporary_file

  for temporary_file in "${run_environment_file:-}" "${output_path_file:-}" "${top_output_file:-}"; do
    if [[ -n "$temporary_file" && -f "$temporary_file" ]]; then
      rm -f -- "$temporary_file"
    fi
  done
}

cleanup() {
  stop_top
  stop_agent
  remove_temporary_files
}

port_is_available() {
  ! ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:|\])15034$'
}

write_cpu_loads() {
  local input_log="$1"
  local output_file="$2"

  printf 'timestamp\tlogged_cpu_percent\n' >"$output_file"
  sed -nE 's/^([^ ]+ [^ ]+).*\[CpuWorker\] Current Load: ([0-9.]+)%.*/\1\t\2/p' "$input_log" >>"$output_file"
}

maximum_logged_cpu() {
  awk -F '\t' 'NR > 1 && $2 ~ /^[0-9.]+$/ {if ($2 > max) max=$2} END {print max+0}' "$1"
}

maximum_top_cpu() {
  awk '$NF == "agent-leak-app" && $9 ~ /^[0-9.]+$/ {if ($9 > max) max=$9} END {print max+0}' "$1"
}

main() {
  if (($# != 2)); then
    usage >&2
    exit 2
  fi

  local phase="$1"
  local cpu_limit="$2"
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
  local top_pid
  local stopped_after_observation=false
  local cpu_threshold_observed=false
  local termination_reason
  local termination_signal='none'
  local max_logged_cpu
  local max_top_cpu

  [[ "$(uname -s)" == 'Linux' ]] || fail '이 스크립트는 Linux 환경에서만 실행할 수 있습니다.'
  [[ "$(id -u)" -ne 0 ]] || fail 'root가 아닌 일반 사용자 계정으로 실행하세요.'
  [[ "$phase" == 'before' || "$phase" == 'after' ]] || fail '첫 번째 인수는 before 또는 after여야 합니다.'
  [[ "$cpu_limit" =~ ^[0-9]+$ ]] || fail 'CPU_MAX_OCCUPY는 정수여야 합니다.'
  ((cpu_limit >= 10 && cpu_limit <= 100)) || fail 'CPU_MAX_OCCUPY는 10~100 사이여야 합니다.'

  command -v ss >/dev/null 2>&1 || fail "'ss' 명령을 찾을 수 없습니다."
  command -v mktemp >/dev/null 2>&1 || fail "'mktemp' 명령을 찾을 수 없습니다."
  command -v top >/dev/null 2>&1 || fail "'top' 명령을 찾을 수 없습니다."

  configured_agent_home="${AGENT_HOME:-$HOME/agent-leak-lab}"
  environment_file="${AGENT_ENV_FILE:-$configured_agent_home/agent.env}"
  [[ -f "$environment_file" ]] || fail "환경 파일이 없습니다: $environment_file"

  # shellcheck disable=SC1090
  source "$environment_file"

  [[ -x "$AGENT_BINARY" ]] || fail "바이너리를 실행할 수 없습니다: $AGENT_BINARY"
  [[ -d "$AGENT_LOG_DIR" && -w "$AGENT_LOG_DIR" ]] || fail "로그 디렉터리에 쓸 수 없습니다: $AGENT_LOG_DIR"
  [[ "$AGENT_PORT" == '15034' ]] || fail 'AGENT_PORT는 15034여야 합니다.'
  port_is_available || fail '0.0.0.0:15034 포트가 이미 사용 중입니다.'

  sample_count="${CPU_SAMPLE_COUNT:-60}"
  interval_seconds="${CPU_INTERVAL_SECONDS:-1}"
  [[ "$sample_count" =~ ^[1-9][0-9]*$ ]] || fail 'CPU_SAMPLE_COUNT는 1 이상의 정수여야 합니다.'
  [[ "$interval_seconds" =~ ^[1-9][0-9]*$ ]] || fail 'CPU_INTERVAL_SECONDS는 1 이상의 정수여야 합니다.'

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  project_dir="$(cd -- "$script_dir/.." && pwd)"
  evidence_root="${EVIDENCE_ROOT:-$project_dir/evidence}"
  mkdir -p "$evidence_root" "$AGENT_LOG_DIR"

  run_environment_file="$(mktemp "$AGENT_HOME/cpu-experiment.XXXXXX.env")"
  output_path_file="$(mktemp "$AGENT_HOME/cpu-output-path.XXXXXX.txt")"
  top_output_file="$(mktemp "$AGENT_HOME/cpu-top.XXXXXX.txt")"
  run_log="$AGENT_LOG_DIR/cpu-$phase-cpu-max-$cpu_limit.log"
  trap cleanup EXIT INT TERM

  {
    printf 'export AGENT_HOME=%q\n' "$AGENT_HOME"
    printf 'export AGENT_PORT=%q\n' "$AGENT_PORT"
    printf 'export AGENT_UPLOAD_DIR=%q\n' "$AGENT_UPLOAD_DIR"
    printf 'export AGENT_KEY_PATH=%q\n' "$AGENT_KEY_PATH"
    printf 'export AGENT_LOG_DIR=%q\n' "$AGENT_LOG_DIR"
    printf 'export MEMORY_LIMIT=512\n'
    printf 'export CPU_MAX_OCCUPY=%q\n' "$cpu_limit"
    printf 'export MULTI_THREAD_ENABLE=%q\n' "$MULTI_THREAD_ENABLE"
    printf 'export AGENT_BINARY=%q\n' "$AGENT_BINARY"
  } >"$run_environment_file"
  chmod 0600 "$run_environment_file"

  : >"$run_log"
  start_epoch="$(date +%s)"
  MEMORY_LIMIT=512 CPU_MAX_OCCUPY="$cpu_limit" "$AGENT_BINARY" >"$run_log" 2>&1 &
  launcher_pid=$!
  monitored_pid=''
  top_pid=''

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

  LC_ALL=C top -b -d "$interval_seconds" -n "$sample_count" -p "$monitored_pid" >"$top_output_file" 2>&1 &
  top_pid=$!

  AGENT_ENV_FILE="$run_environment_file" \
    EVIDENCE_ROOT="$evidence_root" \
    EVIDENCE_INTERVAL_SECONDS="$interval_seconds" \
    EVIDENCE_SAMPLE_COUNT="$sample_count" \
    EVIDENCE_OUTPUT_PATH_FILE="$output_path_file" \
    "$script_dir/collect_evidence.sh" "$phase" cpu "$monitored_pid" "$run_log"

  output_dir="$(<"$output_path_file")"
  stop_top
  top_pid=''

  if process_exists "$monitored_pid"; then
    if [[ "$phase" == 'before' ]]; then
      fail "$sample_count회 관제하는 동안 CPU 임계치 종료가 발생하지 않았습니다. 표본 수를 늘려 다시 실행하세요."
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
  cp -- "$top_output_file" "$output_dir/top-timeseries.txt"
  cp -- "$run_log" "$output_dir/application-full.log"
  write_cpu_loads "$run_log" "$output_dir/cpu-worker-load.tsv"
  max_logged_cpu="$(maximum_logged_cpu "$output_dir/cpu-worker-load.tsv")"
  max_top_cpu="$(maximum_top_cpu "$output_dir/top-timeseries.txt")"

  if grep -Fqi 'CPU Threshold Violated' "$run_log"; then
    cpu_threshold_observed=true
    termination_reason='CPU Threshold Violated'
  elif [[ "$stopped_after_observation" == true ]]; then
    termination_reason='Observation completed without CPU threshold; process stopped by experiment script'
  elif grep -Eqi 'WAITING|BLOCKED|DEADLOCK' "$run_log"; then
    termination_reason='Deadlock-related state observed (CPU threshold not observed)'
  else
    termination_reason='Process exited without CPU threshold violation'
  fi

  if ((exit_code == 143)); then
    termination_signal='SIGTERM'
  elif ((exit_code == 137)); then
    termination_signal='SIGKILL'
  fi

  if [[ "$phase" == 'before' ]]; then
    [[ "$cpu_threshold_observed" == true ]] || fail "기본 설정에서 'CPU Threshold Violated'를 찾지 못했습니다."
    [[ "$termination_signal" == 'SIGTERM' ]] || fail "기본 설정의 종료 신호가 SIGTERM이 아닙니다. 종료 코드: $exit_code"
  else
    [[ "$cpu_threshold_observed" == false ]] || fail '변경 설정에서도 CPU 임계치 종료가 발생했습니다.'
  fi

  {
    printf 'phase=%s\n' "$phase"
    printf 'memory_limit=512\n'
    printf 'cpu_max_occupy=%s\n' "$cpu_limit"
    printf 'duration_seconds=%s\n' "$duration_seconds"
    printf 'process_exit_code=%s\n' "$exit_code"
    printf 'termination_signal=%s\n' "$termination_signal"
    printf 'cpu_threshold_observed=%s\n' "$cpu_threshold_observed"
    printf 'stopped_after_observation=%s\n' "$stopped_after_observation"
    printf 'max_logged_cpu_percent=%s\n' "$max_logged_cpu"
    printf 'max_top_cpu_percent=%s\n' "$max_top_cpu"
    printf 'termination_reason=%s\n' "$termination_reason"
  } >"$output_dir/run-summary.txt"

  remove_temporary_files
  trap - EXIT INT TERM

  printf '\nCPU 실험 완료\n'
  printf 'CPU_MAX_OCCUPY: %s\n' "$cpu_limit"
  printf '최대 애플리케이션 기록 CPU: %s%%\n' "$max_logged_cpu"
  printf '최대 top 프로세스 CPU: %s%%\n' "$max_top_cpu"
  printf '종료 신호: %s\n' "$termination_signal"
  printf 'CPU 임계치 관찰 여부: %s\n' "$cpu_threshold_observed"
  printf '종료/관찰 결과: %s\n' "$termination_reason"
  printf '증거 저장 위치: %s\n' "$output_dir"
}

main "$@"
