#!/usr/bin/env bash

set -euo pipefail

export COLUMNS=140
export LINES=40

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
사용법: run_deadlock_experiment.sh <before|after> <true|false>

예시:
  ./scripts/run_deadlock_experiment.sh before true
  ./scripts/run_deadlock_experiment.sh after false

선택 환경변수:
  DEADLOCK_SAMPLE_COUNT      관제 횟수(기본값: 30)
  DEADLOCK_INTERVAL_SECONDS  관제 간격(기본값: 1)
  EVIDENCE_ROOT              증거 저장 폴더(기본값: <프로젝트>/evidence)
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

  for temporary_file in "${run_environment_file:-}" "${output_path_file:-}"; do
    if [[ -n "$temporary_file" && -f "$temporary_file" ]]; then
      rm -f -- "$temporary_file"
    fi
  done
}

cleanup() {
  stop_agent

  if [[ -n "${launcher_pid:-}" ]]; then
    wait "$launcher_pid" 2>/dev/null || true
  fi

  remove_temporary_files
}

port_is_available() {
  ! ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:|\])15034$'
}

metric_value() {
  local metrics_file="$1"
  local column="$2"
  local position="$3"

  if [[ "$position" == 'first' ]]; then
    awk -F '\t' -v column="$column" 'NR > 1 && $column ~ /^[0-9.]+$/ {print $column; exit}' "$metrics_file"
  else
    awk -F '\t' -v column="$column" 'NR > 1 && $column ~ /^[0-9.]+$/ {value=$column} END {print value}' "$metrics_file"
  fi
}

main() {
  if (($# != 2)); then
    usage >&2
    exit 2
  fi

  local phase="$1"
  local multi_thread_enable="$2"
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
  local deadlock_observed=false
  local process_alive_after_observation=false
  local first_cpu
  local final_cpu
  local first_rss
  local final_rss
  local final_thread_count

  [[ "$(uname -s)" == 'Linux' ]] || fail '이 스크립트는 Linux 환경에서만 실행할 수 있습니다.'
  [[ "$(id -u)" -ne 0 ]] || fail 'root가 아닌 일반 사용자 계정으로 실행하세요.'
  [[ "$phase" == 'before' || "$phase" == 'after' ]] || fail '첫 번째 인수는 before 또는 after여야 합니다.'
  [[ "$multi_thread_enable" == 'true' || "$multi_thread_enable" == 'false' ]] || fail '두 번째 인수는 true 또는 false여야 합니다.'

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

  sample_count="${DEADLOCK_SAMPLE_COUNT:-30}"
  interval_seconds="${DEADLOCK_INTERVAL_SECONDS:-1}"
  [[ "$sample_count" =~ ^[1-9][0-9]*$ ]] || fail 'DEADLOCK_SAMPLE_COUNT는 1 이상의 정수여야 합니다.'
  [[ "$interval_seconds" =~ ^[1-9][0-9]*$ ]] || fail 'DEADLOCK_INTERVAL_SECONDS는 1 이상의 정수여야 합니다.'

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  project_dir="$(cd -- "$script_dir/.." && pwd)"
  evidence_root="${EVIDENCE_ROOT:-$project_dir/evidence}"
  mkdir -p "$evidence_root" "$AGENT_LOG_DIR"

  run_environment_file="$(mktemp "$AGENT_HOME/deadlock-experiment.XXXXXX.env")"
  output_path_file="$(mktemp "$AGENT_HOME/deadlock-output-path.XXXXXX.txt")"
  run_log="$AGENT_LOG_DIR/deadlock-$phase-multi-thread-$multi_thread_enable.log"
  trap cleanup EXIT INT TERM

  {
    printf 'export AGENT_HOME=%q\n' "$AGENT_HOME"
    printf 'export AGENT_PORT=%q\n' "$AGENT_PORT"
    printf 'export AGENT_UPLOAD_DIR=%q\n' "$AGENT_UPLOAD_DIR"
    printf 'export AGENT_KEY_PATH=%q\n' "$AGENT_KEY_PATH"
    printf 'export AGENT_LOG_DIR=%q\n' "$AGENT_LOG_DIR"
    printf 'export MEMORY_LIMIT=512\n'
    printf 'export CPU_MAX_OCCUPY=40\n'
    printf 'export MULTI_THREAD_ENABLE=%q\n' "$multi_thread_enable"
    printf 'export AGENT_BINARY=%q\n' "$AGENT_BINARY"
  } >"$run_environment_file"
  chmod 0600 "$run_environment_file"

  : >"$run_log"
  start_epoch="$(date +%s)"
  MEMORY_LIMIT=512 CPU_MAX_OCCUPY=40 MULTI_THREAD_ENABLE="$multi_thread_enable" "$AGENT_BINARY" >"$run_log" 2>&1 &
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
    "$script_dir/collect_evidence.sh" "$phase" deadlock "$monitored_pid" "$run_log"

  output_dir="$(<"$output_path_file")"

  if process_exists "$monitored_pid"; then
    process_alive_after_observation=true
    LC_ALL=C ps -L -p "$monitored_pid" -o pid,lwp,psr,stat,wchan:40,%cpu,%mem,comm >"$output_dir/thread-wait-channels.txt"
    LC_ALL=C top -H -b -n 1 -p "$monitored_pid" >"$output_dir/thread-top.txt"
  else
    fail "관찰 중 프로세스가 종료되었습니다. PID: $monitored_pid"
  fi

  cp -- "$run_log" "$output_dir/application-full.log"

  if grep -Eq 'Worker-Thread-1.*WAITING for \[Socket_Pool_B\].*BLOCKED' "$run_log" \
    && grep -Eq 'Worker-Thread-2.*WAITING for \[Shared_Memory_A\].*BLOCKED' "$run_log"; then
    deadlock_observed=true
  fi

  if [[ "$phase" == 'before' ]]; then
    [[ "$deadlock_observed" == true ]] || fail 'before 로그에서 상호 WAITING/BLOCKED 상태를 확인하지 못했습니다.'
  else
    [[ "$deadlock_observed" == false ]] || fail '변경 설정에서도 상호 WAITING/BLOCKED 상태가 발생했습니다.'
  fi

  first_cpu="$(metric_value "$output_dir/metrics.tsv" 5 first)"
  final_cpu="$(metric_value "$output_dir/metrics.tsv" 5 last)"
  first_rss="$(metric_value "$output_dir/metrics.tsv" 7 first)"
  final_rss="$(metric_value "$output_dir/metrics.tsv" 7 last)"
  final_thread_count="$(metric_value "$output_dir/metrics.tsv" 9 last)"

  stop_agent
  set +e
  wait "$launcher_pid" 2>/dev/null
  exit_code=$?
  set -e
  launcher_pid=''
  monitored_pid=''

  end_epoch="$(date +%s)"
  duration_seconds=$((end_epoch - start_epoch))

  {
    printf 'phase=%s\n' "$phase"
    printf 'memory_limit=512\n'
    printf 'cpu_max_occupy=40\n'
    printf 'multi_thread_enable=%s\n' "$multi_thread_enable"
    printf 'observation_seconds=%s\n' "$sample_count"
    printf 'process_alive_after_observation=%s\n' "$process_alive_after_observation"
    printf 'deadlock_observed=%s\n' "$deadlock_observed"
    printf 'first_cpu_percent=%s\n' "$first_cpu"
    printf 'final_cpu_percent=%s\n' "$final_cpu"
    printf 'first_rss_kib=%s\n' "$first_rss"
    printf 'final_rss_kib=%s\n' "$final_rss"
    printf 'final_thread_count=%s\n' "$final_thread_count"
    printf 'cleanup_exit_code=%s\n' "$exit_code"
    printf 'duration_seconds=%s\n' "$duration_seconds"
  } >"$output_dir/run-summary.txt"

  remove_temporary_files
  trap - EXIT INT TERM

  printf '\nDeadlock 실험 완료\n'
  printf 'MULTI_THREAD_ENABLE: %s\n' "$multi_thread_enable"
  printf '관찰 종료 시 프로세스 생존: %s\n' "$process_alive_after_observation"
  printf 'Deadlock 관찰 여부: %s\n' "$deadlock_observed"
  printf 'CPU 변화: %s%% -> %s%%\n' "$first_cpu" "$final_cpu"
  printf 'RSS 변화: %sKiB -> %sKiB\n' "$first_rss" "$final_rss"
  printf '최종 스레드 수: %s\n' "$final_thread_count"
  printf '증거 저장 위치: %s\n' "$output_dir"
}

main "$@"
