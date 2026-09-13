#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
사용법: verify_deadlock_evidence.sh <before 증거 폴더> <after 증거 폴더>
EOF
}

require_file() {
  [[ -f "$1" ]] || fail "필수 증거 파일이 없습니다: $1"
}

value_from_file() {
  local input_file="$1"
  local key="$2"

  awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1)}' "$input_file"
}

absolute_difference() {
  local first="$1"
  local second="$2"

  if ((first >= second)); then
    printf '%s\n' "$((first - second))"
  else
    printf '%s\n' "$((second - first))"
  fi
}

main() {
  if (($# != 2)); then
    usage >&2
    exit 2
  fi

  local before_dir="$1"
  local after_dir="$2"
  local before_settings
  local after_settings
  local before_summary
  local after_summary
  local before_cpu_delta
  local before_rss_delta
  local blocked_waiter_count
  local evidence_dir

  [[ -d "$before_dir" ]] || fail "before 증거 폴더가 없습니다: $before_dir"
  [[ -d "$after_dir" ]] || fail "after 증거 폴더가 없습니다: $after_dir"

  for evidence_dir in "$before_dir" "$after_dir"; do
    require_file "$evidence_dir/settings.txt"
    require_file "$evidence_dir/metrics.tsv"
    require_file "$evidence_dir/application-full.log"
    require_file "$evidence_dir/run-summary.txt"
    require_file "$evidence_dir/thread-wait-channels.txt"
    require_file "$evidence_dir/thread-top.txt"
  done

  before_settings="$before_dir/settings.txt"
  after_settings="$after_dir/settings.txt"
  before_summary="$before_dir/run-summary.txt"
  after_summary="$after_dir/run-summary.txt"

  [[ "$(value_from_file "$before_settings" MEMORY_LIMIT)" == "$(value_from_file "$after_settings" MEMORY_LIMIT)" ]] || fail 'Deadlock 실험에서 MEMORY_LIMIT가 함께 변경됐습니다.'
  [[ "$(value_from_file "$before_settings" CPU_MAX_OCCUPY)" == "$(value_from_file "$after_settings" CPU_MAX_OCCUPY)" ]] || fail 'Deadlock 실험에서 CPU_MAX_OCCUPY가 함께 변경됐습니다.'
  [[ "$(value_from_file "$before_settings" MULTI_THREAD_ENABLE)" == 'true' ]] || fail 'before의 MULTI_THREAD_ENABLE이 true가 아닙니다.'
  [[ "$(value_from_file "$after_settings" MULTI_THREAD_ENABLE)" == 'false' ]] || fail 'after의 MULTI_THREAD_ENABLE이 false가 아닙니다.'

  grep -Fq 'process_alive_after_observation=true' "$before_summary" || fail 'before PID가 관찰 종료까지 살아 있다는 증거가 없습니다.'
  grep -Fq 'deadlock_observed=true' "$before_summary" || fail 'before 요약에서 Deadlock을 확인하지 못했습니다.'
  grep -Eq 'Worker-Thread-1.*WAITING for \[Socket_Pool_B\].*BLOCKED' "$before_dir/application-full.log" || fail 'Worker-Thread-1의 Socket_Pool_B 대기 로그가 없습니다.'
  grep -Eq 'Worker-Thread-2.*WAITING for \[Shared_Memory_A\].*BLOCKED' "$before_dir/application-full.log" || fail 'Worker-Thread-2의 Shared_Memory_A 대기 로그가 없습니다.'

  blocked_waiter_count="$(grep -c 'futex_wait_queue' "$before_dir/thread-wait-channels.txt")"
  ((blocked_waiter_count >= 3)) || fail 'before 스레드의 futex 대기 상태가 충분히 확인되지 않았습니다.'

  before_cpu_delta="$(absolute_difference "$(value_from_file "$before_summary" first_cpu_percent | cut -d. -f1)" "$(value_from_file "$before_summary" final_cpu_percent | cut -d. -f1)")"
  before_rss_delta="$(absolute_difference "$(value_from_file "$before_summary" first_rss_kib)" "$(value_from_file "$before_summary" final_rss_kib)")"
  ((before_rss_delta <= 1024)) || fail 'before 결과에서 RSS가 정체되지 않았습니다.'

  grep -Fq 'process_alive_after_observation=true' "$after_summary" || fail 'after PID가 관찰 종료까지 살아 있다는 증거가 없습니다.'
  grep -Fq 'deadlock_observed=false' "$after_summary" || fail 'after 요약에서 Deadlock 미발생을 확인하지 못했습니다.'

  if grep -Eq 'WAITING for .*Status: BLOCKED' "$after_dir/application-full.log"; then
    fail 'after 로그에도 상호 자원 대기 상태가 발생했습니다.'
  fi

  grep -Fq '[Scheduler] All tasks completed.' "$after_dir/application-full.log" || fail 'after 로그에 작업 완료 기록이 없습니다.'

  printf 'Deadlock Before & After 증거 검증 완료\n'
  printf 'before MULTI_THREAD_ENABLE: true\n'
  printf 'before 관찰 종료 시 PID 생존: true\n'
  printf 'before futex 대기 스레드 수: %s\n' "$blocked_waiter_count"
  printf 'before CPU 변화 폭(정수부): %s%%\n' "$before_cpu_delta"
  printf 'before RSS 변화 폭: %sKiB\n' "$before_rss_delta"
  printf 'after MULTI_THREAD_ENABLE: false\n'
  printf 'after 작업 완료 로그: true\n'
  printf 'after Deadlock 관찰 여부: false\n'
}

main "$@"
