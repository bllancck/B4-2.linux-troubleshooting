#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
사용법: verify_cpu_evidence.sh <before 증거 폴더> <after 증거 폴더>
EOF
}

require_file() {
  [[ -f "$1" ]] || fail "필수 증거 파일이 없습니다: $1"
}

setting_value() {
  local settings_file="$1"
  local key="$2"

  awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1)}' "$settings_file"
}

first_logged_cpu() {
  awk -F '\t' 'NR > 1 && $2 ~ /^[0-9.]+$/ {print $2; exit}' "$1"
}

maximum_logged_cpu() {
  awk -F '\t' 'NR > 1 && $2 ~ /^[0-9.]+$/ {if ($2 > max) max=$2} END {print max+0}' "$1"
}

summary_value() {
  local summary_file="$1"
  local key="$2"

  awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1)}' "$summary_file"
}

main() {
  if (($# != 2)); then
    usage >&2
    exit 2
  fi

  local before_dir="$1"
  local after_dir="$2"
  local before_cpu_limit
  local after_cpu_limit
  local before_memory_limit
  local after_memory_limit
  local before_first_cpu
  local before_max_cpu
  local before_top_cpu
  local evidence_dir

  [[ -d "$before_dir" ]] || fail "before 증거 폴더가 없습니다: $before_dir"
  [[ -d "$after_dir" ]] || fail "after 증거 폴더가 없습니다: $after_dir"

  for evidence_dir in "$before_dir" "$after_dir"; do
    require_file "$evidence_dir/settings.txt"
    require_file "$evidence_dir/metrics.tsv"
    require_file "$evidence_dir/application-full.log"
    require_file "$evidence_dir/run-summary.txt"
    require_file "$evidence_dir/cpu-worker-load.tsv"
    require_file "$evidence_dir/top-timeseries.txt"
  done

  before_cpu_limit="$(setting_value "$before_dir/settings.txt" CPU_MAX_OCCUPY)"
  after_cpu_limit="$(setting_value "$after_dir/settings.txt" CPU_MAX_OCCUPY)"
  before_memory_limit="$(setting_value "$before_dir/settings.txt" MEMORY_LIMIT)"
  after_memory_limit="$(setting_value "$after_dir/settings.txt" MEMORY_LIMIT)"
  [[ "$before_cpu_limit" =~ ^[0-9]+$ && "$after_cpu_limit" =~ ^[0-9]+$ ]] || fail 'CPU_MAX_OCCUPY 증거가 정수가 아닙니다.'
  ((after_cpu_limit < before_cpu_limit)) || fail 'after의 CPU_MAX_OCCUPY가 before보다 작지 않습니다.'
  [[ "$before_memory_limit" == "$after_memory_limit" ]] || fail 'CPU 실험에서 MEMORY_LIMIT가 함께 변경됐습니다.'

  before_first_cpu="$(first_logged_cpu "$before_dir/cpu-worker-load.tsv")"
  before_max_cpu="$(maximum_logged_cpu "$before_dir/cpu-worker-load.tsv")"
  before_top_cpu="$(summary_value "$before_dir/run-summary.txt" max_top_cpu_percent)"
  [[ -n "$before_first_cpu" ]] || fail 'before 결과에 CpuWorker 부하 표본이 없습니다.'
  awk -v first="$before_first_cpu" -v maximum="$before_max_cpu" 'BEGIN {exit !(maximum > first)}' || fail 'before 결과에서 내부 CPU 판정값 상승을 확인하지 못했습니다.'

  grep -Fqi 'CPU Threshold Violated' "$before_dir/application-full.log" || fail 'before 로그에 CPU 임계치 초과 기록이 없습니다.'
  grep -Fq 'termination_signal=SIGTERM' "$before_dir/run-summary.txt" || fail 'before 요약에 SIGTERM 종료 기록이 없습니다.'
  grep -Fq 'cpu_threshold_observed=true' "$before_dir/run-summary.txt" || fail 'before 요약에서 CPU 임계치 동작을 확인하지 못했습니다.'
  grep -Fq 'PROCESS_EXITED' "$before_dir/metrics.tsv" || fail 'before 관제 데이터에 종료 행이 없습니다.'

  if grep -Fqi 'CPU Threshold Violated' "$after_dir/application-full.log"; then
    fail 'after 로그에도 CPU 임계치 초과가 발생했습니다.'
  fi

  grep -Fq 'cpu_threshold_observed=false' "$after_dir/run-summary.txt" || fail 'after 요약에서 CPU 임계치 미발생을 확인하지 못했습니다.'
  grep -Fq 'stopped_after_observation=true' "$after_dir/run-summary.txt" || fail 'after 프로세스가 관찰 시간까지 생존했다는 기록이 없습니다.'

  printf 'CPU Before & After 증거 검증 완료\n'
  printf 'before CPU_MAX_OCCUPY: %s%%\n' "$before_cpu_limit"
  printf 'before 내부 CpuWorker 판정값: %s%% -> 최대 %s%%\n' "$before_first_cpu" "$before_max_cpu"
  printf 'before top 프로세스 최대 관측값: %s%%\n' "$before_top_cpu"
  printf 'before 종료 신호: SIGTERM\n'
  printf 'after CPU_MAX_OCCUPY: %s%%\n' "$after_cpu_limit"
  printf 'after CPU 임계치 관찰 여부: false\n'
  printf 'after 관찰 시간까지 프로세스 생존: true\n'
}

main "$@"
