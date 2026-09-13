#!/bin/bash
# /code-review が異常終了したときに残る作業ディレクトリ($HOME/.claude/cache/code-review/<run-id>/) を、1日以上前のものから掃除する。
# 正常終了時は review-orchestrator.js の「後始末」フェーズが自分のディレクトリを名指しで削除するので対象外（このスクリプトは異常終了時の残骸だけを掃除する）。
# launchd / systemd timer で1日ごとに実行される。
set -euo pipefail

CACHE_DIR="$HOME/.claude/cache/code-review"
LOG_FILE="$HOME/.claude/scripts/nt-code-review-cache-cleanup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

if [ ! -d "$CACHE_DIR" ]; then
    log "対象ディレクトリなし、スキップ"
    exit 0
fi

DELETED=$(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +1 -print -exec rm -rf {} \;)

if [ -n "$DELETED" ]; then
    log "削除:"
    echo "$DELETED" | while IFS= read -r d; do log "  $d"; done
else
    log "削除対象なし"
fi
