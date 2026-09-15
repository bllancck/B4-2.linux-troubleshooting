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
사용법: collect_evidence.sh <before|after> <실험 이름> <PID> [애플리케이션 로그]

예시:
  ./scripts/collect_evidence.sh before oom 1234 "$AGENT_LOG_DIR/agent.log"

선택 환경변수:
  EVIDENCE_INTERVAL_SECONDS  관제 수집 간격(기본값: 1)
  EVIDENCE_SAMPLE_COUNT      관제 수집 횟수(기본값: 5)
  EVIDENCE_ROOT              증거 저장 폴더(기본값: $AGENT_HOME/evidence)
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' 명령을 찾을 수 없습니다."
}

process_exists() {
  ps -p "$1" -o pid= 2>/dev/null | grep -Eq '[0-9]'
}

capture_snapshots() {
  local label="$1"
  local output_dir="$2"
  local pid="$3"

  if ! process_exists "$pid"; then
    printf 'PID %s 프로세스가 이미 종료되었습니다.\n' "$pid" >"$output_dir/process-$label.txt"
    printf 'PID %s 프로세스가 이미 종료되었습니다.\n' "$pid" >"$output_dir/threads-$label.txt"
    printf 'PID %s 프로세스가 이미 종료되었습니다.\n' "$pid" >"$output_dir/top-$label.txt"
    return
  fi

  LC_ALL=C ps -p "$pid" -o pid,ppid,etimes,stat,%cpu,%mem,rss,vsz,nlwp,comm,args >"$output_dir/process-$label.txt"
  LC_ALL=C ps -L -p "$pid" -o pid,lwp,psr,stat,wchan:32,%cpu,%mem,comm >"$output_dir/threads-$label.txt"
  LC_ALL=C top -b -n 1 -p "$pid" >"$output_dir/top-$label.txt"
}

write_settings() {
  local output_file="$1"

  {
    printf 'AGENT_PORT=%s\n' "${AGENT_PORT:-<unset>}"
    printf 'AGENT_UPLOAD_DIR=%s\n' "${AGENT_UPLOAD_DIR:-<unset>}"
    printf 'AGENT_KEY_PATH=%s\n' "${AGENT_KEY_PATH:-<unset>}"
    printf 'AGENT_LOG_DIR=%s\n' "${AGENT_LOG_DIR:-<unset>}"
    printf 'MEMORY_LIMIT=%s\n' "${MEMORY_LIMIT:-<unset>}"
    printf 'CPU_MAX_OCCUPY=%s\n' "${CPU_MAX_OCCUPY:-<unset>}"
    printf 'MULTI_THREAD_ENABLE=%s\n' "${MULTI_THREAD_ENABLE:-<unset>}"
  } >"$output_file"
}

main() {
  if (($# < 3 || $# > 4)); then
    usage >&2
    exit 2
  fi

  local phase="$1"
  local experiment_name="$2"
  local pid="$3"
  local application_log="${4:-}"
  local configured_agent_home
  local environment_file
  local evidence_root
  local interval_seconds
  local sample_count
  local script_dir
  local timestamp
  local output_dir

  [[ "$(uname -s)" == 'Linux' ]] || fail '이 스크립트는 Linux 환경에서만 실행할 수 있습니다.'
  [[ "$phase" == 'before' || "$phase" == 'after' ]] || fail '첫 번째 인수는 before 또는 after여야 합니다.'
  [[ "$experiment_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || fail '실험 이름에는 영문자, 숫자, 점, 밑줄, 하이픈만 사용할 수 있습니다.'
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail 'PID는 1 이상의 정수여야 합니다.'

  require_command date
  require_command ps
  require_command top
  require_command tail

  configured_agent_home="${AGENT_HOME:-$HOME/agent-leak-lab}"
  environment_file="${AGENT_ENV_FILE:-$configured_agent_home/agent.env}"
  [[ -f "$environment_file" ]] || fail "환경 파일이 없습니다: $environment_file. 다른 계정의 AGENT_HOME이 남아 있는지 확인하고 prepare_environment.sh를 다시 실행하세요."

  # shellcheck disable=SC1090
  source "$environment_file"

  evidence_root="${EVIDENCE_ROOT:-$AGENT_HOME/evidence}"
  interval_seconds="${EVIDENCE_INTERVAL_SECONDS:-1}"
  sample_count="${EVIDENCE_SAMPLE_COUNT:-5}"
  [[ "$interval_seconds" =~ ^[1-9][0-9]*$ ]] || fail 'EVIDENCE_INTERVAL_SECONDS는 1 이상의 정수여야 합니다.'
  [[ "$sample_count" =~ ^[1-9][0-9]*$ ]] || fail 'EVIDENCE_SAMPLE_COUNT는 1 이상의 정수여야 합니다.'
  process_exists "$pid" || fail "실행 중인 프로세스를 찾을 수 없습니다. PID: $pid"

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  timestamp="$(date '+%Y%m%d-%H%M%S-%N')"
  output_dir="$evidence_root/$experiment_name/$phase-$timestamp"
  mkdir -p "$output_dir"

  {
    printf 'collected_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'phase=%s\n' "$phase"
    printf 'experiment=%s\n' "$experiment_name"
    printf 'pid=%s\n' "$pid"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'kernel=%s\n' "$(uname -srmo)"
    printf 'monitor_interval_seconds=%s\n' "$interval_seconds"
    printf 'monitor_sample_count=%s\n' "$sample_count"
  } >"$output_dir/metadata.txt"

  write_settings "$output_dir/settings.txt"
  capture_snapshots initial "$output_dir" "$pid"
  "$script_dir/monitor.sh" "$pid" "$output_dir/metrics.tsv" "$interval_seconds" "$sample_count"
  capture_snapshots final "$output_dir" "$pid"

  if [[ -n "$application_log" ]]; then
    [[ -f "$application_log" ]] || fail "애플리케이션 로그 파일이 없습니다: $application_log"
    tail -n 200 "$application_log" >"$output_dir/application-log-tail.txt"
  else
    printf '애플리케이션 로그 경로가 지정되지 않았습니다.\n' >"$output_dir/application-log-tail.txt"
  fi

  if [[ -n "${EVIDENCE_OUTPUT_PATH_FILE:-}" ]]; then
    printf '%s\n' "$output_dir" >"$EVIDENCE_OUTPUT_PATH_FILE"
  fi

  printf '\n증거 수집 완료\n'
  printf '구분: %s\n' "$phase"
  printf '실험: %s\n' "$experiment_name"
  printf '저장 위치: %s\n' "$output_dir"
}

main "$@"
