#!/usr/bin/env bash

set -u

if (($# < 1 || $# > 3)); then
  echo "사용법: bash scripts/monitor.sh <PID> [관찰 횟수] [저장 파일]" >&2
  exit 1
fi

PID="$1"
COUNT="${2:-30}"
OUTPUT="${3:-monitor.log}"

if [[ ! "$PID" =~ ^[1-9][0-9]*$ ]] || [[ ! "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "오류: PID와 관찰 횟수는 1 이상의 정수여야 합니다." >&2
  exit 1
fi

printf 'TIME\tPID\tSTATE\tCPU%%\tMEM%%\tRSS(KiB)\n' | tee "$OUTPUT"

for ((i = 1; i <= COUNT; i++)); do
  ROW="$(ps -p "$PID" -o pid=,stat=,%cpu=,%mem=,rss= 2>/dev/null)"

  if [[ -z "$ROW" ]]; then
    printf '%s\t%s\tPROCESS_EXITED\n' "$(date '+%H:%M:%S')" "$PID" | tee -a "$OUTPUT"
    break
  fi

  printf '%s\t%s\n' "$(date '+%H:%M:%S')" "$ROW" | tee -a "$OUTPUT"
  sleep 1
done

echo "저장 완료: $OUTPUT"
