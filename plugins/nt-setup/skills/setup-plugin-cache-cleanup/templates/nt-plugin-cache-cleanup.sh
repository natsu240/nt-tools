#!/bin/bash
# Claude Code はセッション開始時に目印を置くが、プロセスが終了しても消さないため溜まり続ける。
#
# **目印の中身にある procStart を判定に使うな。** 中身が空のファイルが一定数あり、ファイル名の pid だけで判定する経路がどうしても必要になる。
set -euo pipefail

CACHE_DIR="$HOME/.claude/plugins/cache"
LOG_FILE="$HOME/.claude/scripts/nt-plugin-cache-cleanup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

if [ ! -d "$CACHE_DIR" ]; then
    log "対象ディレクトリなし、スキップ"
    exit 0
fi

# claude が1つも動いていなければ grep が空を返すので、そのときは全件が削除対象になる（誰も使っていない状態なので消して問題ない）。set -e で落ちないよう || true を付ける。
LIVE_PIDS=$(ps -eo pid,command | grep '[c]laude' | awk '{print $1}' | sort -un | paste -sd'|' - || true)

if [ -n "$LIVE_PIDS" ]; then
    # ファイル名は <pid> か <pid>.tmp.<hex> の形。この形に一致するものだけを残す。
    KEEP_PATTERN="/($LIVE_PIDS)(\.tmp\.[0-9a-f]+)?$"
else
    # ファイルパスは空行にならないので、この条件では1件も残らない。
    KEEP_PATTERN="^$"
fi

TOTAL=0

while IFS= read -r in_use_dir; do
    STALE=$(find "$in_use_dir" -type f | grep -vE "$KEEP_PATTERN" || true)
    [ -n "$STALE" ] || continue

    COUNT=$(printf '%s\n' "$STALE" | wc -l | tr -d ' ')
    printf '%s\n' "$STALE" | tr '\n' '\0' | xargs -0 rm -f
    TOTAL=$(( TOTAL + COUNT ))
    log "  ${COUNT} 件削除: ${in_use_dir#"$CACHE_DIR"/}"
done < <(find "$CACHE_DIR" -type d -name '.in_use')

if [ "$TOTAL" -gt 0 ]; then
    log "合計 ${TOTAL} 件削除（残した pid: ${LIVE_PIDS:-なし}）"
else
    log "削除対象なし"
fi
