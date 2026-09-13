#!/usr/bin/env bash

set -euo pipefail

export COLUMNS=120
export LINES=40

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

process_exists() {
  ps -p "$1" -o pid= 2>/dev/null | grep -Eq '[0-9]'
}

usage() {
  cat <<'EOF'
사용법: monitor.sh <PID> <출력 파일> [수집 간격(초)] [수집 횟수]

예시:
  ./scripts/monitor.sh 1234 ./metrics.tsv 1 30
EOF
}

main() {
  if (($# < 2 || $# > 4)); then
    usage >&2
    exit 2
  fi

  local pid="$1"
  local output_file="$2"
  local interval_seconds="${3:-1}"
  local sample_count="${4:-30}"
  local sample
  local values

  [[ "$(uname -s)" == 'Linux' ]] || fail '이 스크립트는 Linux 환경에서만 실행할 수 있습니다.'
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail 'PID는 1 이상의 정수여야 합니다.'
  [[ "$interval_seconds" =~ ^[1-9][0-9]*$ ]] || fail '수집 간격은 1 이상의 정수여야 합니다.'
  [[ "$sample_count" =~ ^[1-9][0-9]*$ ]] || fail '수집 횟수는 1 이상의 정수여야 합니다.'
  command -v ps >/dev/null 2>&1 || fail "'ps' 명령을 찾을 수 없습니다."
  process_exists "$pid" || fail "실행 중인 프로세스를 찾을 수 없습니다. PID: $pid"

  mkdir -p "$(dirname -- "$output_file")"
  printf 'timestamp\tpid\telapsed_seconds\tstate\tcpu_percent\tmemory_percent\trss_kib\tvsz_kib\tthread_count\tcommand\n' >"$output_file"

  for ((sample = 1; sample <= sample_count; sample++)); do
    values="$(LC_ALL=C ps -p "$pid" -o pid=,etimes=,stat=,%cpu=,%mem=,rss=,vsz=,nlwp=,comm= 2>/dev/null | awk '{$1=$1; print}' OFS='\t' || true)"

    if [[ -z "$values" ]]; then
      printf '%s\t%s\t\tPROCESS_EXITED\t\t\t\t\t\t\n' "$(date --iso-8601=seconds)" "$pid" >>"$output_file"
      printf '프로세스가 종료되어 수집을 마칩니다. PID: %s\n' "$pid"
      break
    fi

    printf '%s\t%s\n' "$(date --iso-8601=seconds)" "$values" >>"$output_file"

    if ((sample < sample_count)); then
      sleep "$interval_seconds"
    fi
  done

  printf '관제 데이터 저장 완료: %s\n' "$output_file"
}

main "$@"
