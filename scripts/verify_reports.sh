#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

verify_common_structure() {
  local report="$1"
  local report_dir
  local evidence_link
  local link_count=0

  for heading in \
    '## 1. Description (현상 설명)' \
    '## 2. Evidence & Logs (증거 자료)' \
    '## 3. Root Cause Analysis (원인 분석)' \
    '## 4. Workaround & Verification (조치 및 검증)'; do
    grep -Fxq "$heading" "$report" || fail "필수 섹션이 없습니다: $report ($heading)"
  done

  grep -Fq 'Before' "$report" || fail "Before 결과가 없습니다: $report"
  grep -Fq 'After' "$report" || fail "After 결과가 없습니다: $report"

  if grep -Eqi 'TODO|TBD|추후 작성' "$report"; then
    fail "미완성 표시가 남아 있습니다: $report"
  fi

  report_dir="$(cd -- "$(dirname -- "$report")" && pwd)"
  while IFS= read -r evidence_link; do
    ((link_count += 1))
    [[ -f "$report_dir/$evidence_link" ]] || fail "연결된 증거 파일이 없습니다: $report_dir/$evidence_link"
  done < <(grep -oE '\.\./evidence/[^)]+' "$report" | sort -u)

  ((link_count > 0)) || fail "증거 파일 링크가 없습니다: $report"
}

main() {
  local script_dir
  local project_dir
  local reports_dir
  local report_count
  local report

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  project_dir="$(cd -- "$script_dir/.." && pwd)"
  reports_dir="$project_dir/reports"

  [[ -d "$reports_dir" ]] || fail "리포트 폴더가 없습니다: $reports_dir"
  report_count="$(find "$reports_dir" -maxdepth 1 -type f -name '[0-9][0-9]-*.md' | wc -l)"
  [[ "$report_count" -eq 3 ]] || fail "장애 리포트가 정확히 3건이 아닙니다: $report_count"

  for report in \
    "$reports_dir/01-oom-crash.md" \
    "$reports_dir/02-cpu-latency.md" \
    "$reports_dir/03-deadlock.md"; do
    [[ -f "$report" ]] || fail "리포트가 없습니다: $report"
    verify_common_structure "$report"
  done

  grep -Fq 'Memory limit exceeded' "$reports_dir/01-oom-crash.md" || fail 'OOM 종료 증거가 리포트에 없습니다.'
  grep -Fq 'RSS' "$reports_dir/01-oom-crash.md" || fail 'OOM RSS 증거가 리포트에 없습니다.'
  grep -Fq 'MEMORY_LIMIT=512' "$reports_dir/01-oom-crash.md" || fail 'OOM 변경 설정이 리포트에 없습니다.'

  grep -Fq 'CPU Threshold Violated' "$reports_dir/02-cpu-latency.md" || fail 'CPU 임계치 증거가 리포트에 없습니다.'
  grep -Fq 'SIGTERM' "$reports_dir/02-cpu-latency.md" || fail 'CPU 종료 신호가 리포트에 없습니다.'
  grep -Fq 'top' "$reports_dir/02-cpu-latency.md" || fail 'CPU OS 관제 비교가 리포트에 없습니다.'
  grep -Fq 'CPU_MAX_OCCUPY=40' "$reports_dir/02-cpu-latency.md" || fail 'CPU 변경 설정이 리포트에 없습니다.'

  grep -Fq 'WAITING' "$reports_dir/03-deadlock.md" || fail 'Deadlock WAITING 증거가 리포트에 없습니다.'
  grep -Fq 'BLOCKED' "$reports_dir/03-deadlock.md" || fail 'Deadlock BLOCKED 증거가 리포트에 없습니다.'
  grep -Fq 'futex_wait_queue' "$reports_dir/03-deadlock.md" || fail 'Deadlock 스레드 대기 증거가 리포트에 없습니다.'
  grep -Fq 'MULTI_THREAD_ENABLE=false' "$reports_dir/03-deadlock.md" || fail 'Deadlock 변경 설정이 리포트에 없습니다.'

  printf 'GitHub Issue 형식 리포트 검증 완료\n'
  printf '리포트 수: 3\n'
  printf '각 리포트의 필수 섹션: 4\n'
  printf '증거 링크: 모두 유효\n'
  printf 'Before & After 비교: 모두 포함\n'
}

main "$@"
