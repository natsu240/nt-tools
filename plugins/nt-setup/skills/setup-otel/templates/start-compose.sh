#!/bin/bash
set -euo pipefail

COMPOSE_FILE="$HOME/.claude/otel/compose.yaml"
WAIT_LIMIT_SECONDS=900
POLL_INTERVAL_SECONDS=5

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

# launchd / systemd は対話シェルの PATH を引き継がないため、Homebrew 等の設置先と標準の探索先を自分で並べる
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
DOCKER_BIN=$(command -v docker || true)
if [[ -z "$DOCKER_BIN" ]]; then
  log "docker コマンドが見つからないため中止する（PATH=${PATH}）" >&2
  exit 1
fi

# ログイン直後はコンテナ基盤の仮想マシンが未起動でソケットが存在しないため、応答するまで待つ
deadline=$((SECONDS + WAIT_LIMIT_SECONDS))
until "$DOCKER_BIN" info >/dev/null 2>&1; do
  if ((SECONDS >= deadline)); then
    log "コンテナ基盤が ${WAIT_LIMIT_SECONDS} 秒待っても応答しないため中止する" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done
log "コンテナ基盤の応答を確認した（待ち時間 ${SECONDS} 秒）"

"$DOCKER_BIN" compose -f "$COMPOSE_FILE" up -d
log "compose up -d が完了した"
