#!/usr/bin/env bash

set -euo pipefail

# 이 스크립트는 실험에 필요한 파일만 준비한다.
# 장애 실행과 관찰은 README의 Linux 명령어를 직접 따라 한다.

if (($# > 1)); then
  echo "사용법: bash scripts/setup.sh [작업 경로]" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "오류: Linux 또는 WSL에서 실행하세요." >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  echo "오류: root가 아닌 일반 사용자로 실행하세요." >&2
  exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
  echo "오류: unzip을 먼저 설치하세요." >&2
  exit 1
fi

if ! command -v ss >/dev/null 2>&1; then
  echo "오류: iproute2를 먼저 설치하세요." >&2
  exit 1
fi

if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:|\])15034$'; then
  echo "오류: 15034 포트가 이미 사용 중입니다." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ARCHIVE="$PROJECT_DIR/agent-app-leak.zip"
AGENT_HOME="${1:-$HOME/agent-leak-lab}"

if [[ "$AGENT_HOME" != /* ]]; then
  echo "오류: 작업 경로는 절대 경로여야 합니다." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64 | amd64) BINARY_IN_ZIP="agent-leak-app-x86" ;;
  aarch64 | arm64) BINARY_IN_ZIP="agent-leak-app-arm64" ;;
  *)
    echo "오류: 지원하지 않는 CPU 아키텍처입니다: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ ! -f "$ARCHIVE" ]]; then
  echo "오류: $ARCHIVE 파일이 없습니다." >&2
  exit 1
fi

mkdir -p \
  "$AGENT_HOME/bin" \
  "$AGENT_HOME/upload_files" \
  "$AGENT_HOME/api_keys" \
  "$AGENT_HOME/logs"

unzip -p "$ARCHIVE" "$BINARY_IN_ZIP" >"$AGENT_HOME/bin/agent-leak-app"
chmod 755 "$AGENT_HOME/bin/agent-leak-app"
printf '%s\n' 'agent_api_key_test' >"$AGENT_HOME/api_keys/secret.key"
chmod 600 "$AGENT_HOME/api_keys/secret.key"

{
  printf 'export AGENT_HOME=%q\n' "$AGENT_HOME"
  printf 'export AGENT_PORT=15034\n'
  printf 'export AGENT_UPLOAD_DIR=%q\n' "$AGENT_HOME/upload_files"
  printf 'export AGENT_KEY_PATH=%q\n' "$AGENT_HOME/api_keys"
  printf 'export AGENT_LOG_DIR=%q\n' "$AGENT_HOME/logs"
  printf 'export AGENT_BINARY=%q\n' "$AGENT_HOME/bin/agent-leak-app"
} >"$AGENT_HOME/agent.env"

echo "준비 완료: $AGENT_HOME"
printf '다음 명령: source %q\n' "$AGENT_HOME/agent.env"
