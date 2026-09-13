#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

stop_agent() {
  if [[ -n "${agent_pid:-}" ]] && kill -0 "$agent_pid" 2>/dev/null; then
    kill -TERM "$agent_pid" 2>/dev/null || true

    for _ in 1 2 3 4 5; do
      kill -0 "$agent_pid" 2>/dev/null || break
      sleep 0.2
    done

    if kill -0 "$agent_pid" 2>/dev/null; then
      kill -KILL "$agent_pid" 2>/dev/null || true
    fi

    wait "$agent_pid" 2>/dev/null || true
  fi
}

main() {
  [[ "$(uname -s)" == 'Linux' ]] || fail '이 스크립트는 Linux 환경에서만 실행할 수 있습니다.'
  [[ "$(id -u)" -ne 0 ]] || fail 'root가 아닌 일반 사용자 계정으로 실행하세요.'

  local configured_agent_home
  local environment_file
  local startup_timeout_seconds
  local startup_log
  local ready=false

  configured_agent_home="${AGENT_HOME:-$HOME/agent-leak-lab}"
  environment_file="${AGENT_ENV_FILE:-$configured_agent_home/agent.env}"
  startup_timeout_seconds="${STARTUP_TIMEOUT_SECONDS:-10}"

  [[ -f "$environment_file" ]] || fail "환경 파일이 없습니다: $environment_file"
  [[ "$startup_timeout_seconds" =~ ^[0-9]+$ ]] || fail 'STARTUP_TIMEOUT_SECONDS는 정수여야 합니다.'
  ((startup_timeout_seconds >= 1 && startup_timeout_seconds <= 60)) || fail 'STARTUP_TIMEOUT_SECONDS는 1~60초 사이여야 합니다.'

  # shellcheck disable=SC1090
  source "$environment_file"

  [[ -n "${AGENT_BINARY:-}" ]] || fail 'AGENT_BINARY 환경변수가 없습니다.'
  [[ -x "$AGENT_BINARY" ]] || fail "바이너리를 실행할 수 없습니다: $AGENT_BINARY"
  [[ -d "${AGENT_LOG_DIR:-}" && -w "$AGENT_LOG_DIR" ]] || fail "로그 디렉터리에 쓸 수 없습니다: ${AGENT_LOG_DIR:-<unset>}"

  startup_log="$AGENT_LOG_DIR/startup-verification.log"
  : >"$startup_log"

  "$AGENT_BINARY" >"$startup_log" 2>&1 &
  agent_pid=$!
  trap stop_agent EXIT INT TERM

  for ((second = 0; second < startup_timeout_seconds; second++)); do
    if grep -Fq 'Agent READY' "$startup_log"; then
      ready=true
      break
    fi

    if ! kill -0 "$agent_pid" 2>/dev/null; then
      break
    fi

    sleep 1
  done

  if [[ "$ready" != true ]]; then
    printf '%s\n' '--- 시작 로그 ---'
    cat "$startup_log"
    fail "${startup_timeout_seconds}초 안에 'Agent READY'를 확인하지 못했습니다."
  fi

  kill -0 "$agent_pid" 2>/dev/null || fail "프로세스가 부팅 확인 직후 종료되었습니다. PID: $agent_pid"

  printf '%s\n' '--- 프로세스 확인 ---'
  ps -p "$agent_pid" -o pid=,stat=,comm=,args=
  printf '\n정상 부팅 확인 완료: Agent READY\n'
  printf '확인된 PID: %s\n' "$agent_pid"
  printf '시작 로그: %s\n' "$startup_log"
  printf '장애 실험으로 넘어가지 않도록 확인용 프로세스를 종료합니다.\n'

  stop_agent
  trap - EXIT INT TERM
}

main "$@"
