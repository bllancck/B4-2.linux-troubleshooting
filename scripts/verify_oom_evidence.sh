#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
사용법: verify_oom_evidence.sh <before 증거 폴더> <after 증거 폴더>
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

first_rss() {
  awk -F '\t' 'NR > 1 && $7 ~ /^[0-9]+$/ {print $7; exit}' "$1"
}

maximum_rss() {
  awk -F '\t' 'NR > 1 && $7 ~ /^[0-9]+$/ {if ($7 > max) max=$7} END {print max+0}' "$1"
}

main() {
  if (($# != 2)); then
    usage >&2
    exit 2
  fi

  local before_dir="$1"
  local after_dir="$2"
  local before_limit
  local after_limit
  local before_first_rss
  local before_max_rss
  local after_first_rss
  local after_max_rss
  local evidence_dir

  [[ -d "$before_dir" ]] || fail "before 증거 폴더가 없습니다: $before_dir"
  [[ -d "$after_dir" ]] || fail "after 증거 폴더가 없습니다: $after_dir"

  for evidence_dir in "$before_dir" "$after_dir"; do
    require_file "$evidence_dir/settings.txt"
    require_file "$evidence_dir/metrics.tsv"
    require_file "$evidence_dir/application-full.log"
    require_file "$evidence_dir/run-summary.txt"
  done

  before_limit="$(setting_value "$before_dir/settings.txt" MEMORY_LIMIT)"
  after_limit="$(setting_value "$after_dir/settings.txt" MEMORY_LIMIT)"
  [[ "$before_limit" =~ ^[0-9]+$ && "$after_limit" =~ ^[0-9]+$ ]] || fail 'MEMORY_LIMIT 증거가 정수가 아닙니다.'
  ((after_limit > before_limit)) || fail 'after의 MEMORY_LIMIT가 before보다 크지 않습니다.'

  before_first_rss="$(first_rss "$before_dir/metrics.tsv")"
  before_max_rss="$(maximum_rss "$before_dir/metrics.tsv")"
  after_first_rss="$(first_rss "$after_dir/metrics.tsv")"
  after_max_rss="$(maximum_rss "$after_dir/metrics.tsv")"
  [[ -n "$before_first_rss" && -n "$after_first_rss" ]] || fail 'RSS 관제 표본이 없습니다.'
  ((before_max_rss > before_first_rss)) || fail 'before 결과에서 RSS 증가를 확인하지 못했습니다.'

  grep -Fqi 'Memory limit exceeded' "$before_dir/application-full.log" || fail 'before 로그에 MemoryGuard 임계값 초과 기록이 없습니다.'
  grep -Eqi 'SELF-TERMINATED|Self-terminating process' "$before_dir/application-full.log" || fail 'before 로그에 자기 종료 기록이 없습니다.'
  grep -Fq 'PROCESS_EXITED' "$before_dir/metrics.tsv" || fail 'before 관제 데이터에 종료 행이 없습니다.'

  if grep -Fqi 'Memory limit exceeded' "$after_dir/application-full.log"; then
    fail 'after 로그에도 MemoryGuard 임계값 초과가 발생했습니다.'
  fi

  grep -Fq 'oom_observed=false' "$after_dir/run-summary.txt" || fail 'after 요약에서 OOM 미발생을 확인하지 못했습니다.'
  grep -Fq 'PROCESS_EXITED' "$after_dir/metrics.tsv" || fail 'after 관제 데이터에 종료 행이 없습니다.'

  printf 'OOM Before & After 증거 검증 완료\n'
  printf 'before MEMORY_LIMIT: %sMB\n' "$before_limit"
  printf 'before RSS: %sKiB -> 최대 %sKiB\n' "$before_first_rss" "$before_max_rss"
  printf 'after MEMORY_LIMIT: %sMB\n' "$after_limit"
  printf 'after RSS: %sKiB -> 최대 %sKiB\n' "$after_first_rss" "$after_max_rss"
  printf 'after OOM 관찰 여부: false\n'
}

main "$@"
