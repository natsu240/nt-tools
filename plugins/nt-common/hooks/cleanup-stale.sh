#!/usr/bin/env bash
# SessionStart フック: 古いセッション副産物を自動掃除する。
# Claude Code には SessionEnd hook が無いので、次セッション起動時にまとめて消す方式。
#
# **失敗してもセッション起動は絶対に止めるな。** すべて stderr 飲み + exit 0 で抜ける。

set +e

# 現セッション ID は hook input から取れる（あれば除外）
INPUT_JSON="$(cat 2>/dev/null || true)"
CURRENT_SID="$(printf '%s' "$INPUT_JSON" | jq -r '.session_id // empty' 2>/dev/null)"

# file-history: 7日以上アクセスのないセッションディレクトリ
if [ -d "$HOME/.claude/file-history" ]; then
  find "$HOME/.claude/file-history" -mindepth 1 -maxdepth 1 -type d -mtime +7 \
    ! -name "$CURRENT_SID" -exec rm -rf {} + 2>/dev/null
fi

# scratchpad: /tmp/claude-<uid>/<project>/<session_id>/（macOS の /tmp は /private/tmp へのリンク）
SCRATCH_ROOT="/tmp/claude-$(id -u)"
if [ -d "$SCRATCH_ROOT" ]; then
  find "$SCRATCH_ROOT" -mindepth 2 -maxdepth 2 -type d -mtime +7 \
    ! -name "$CURRENT_SID" -exec rm -rf {} + 2>/dev/null
fi

# hook が置くセッション目印ファイル（Skill/Read/Git 操作の記録用途）。
# セッションごとに増え続けるため掃除する。
if [ -d "$HOME/.claude/hook-state" ]; then
  find "$HOME/.claude/hook-state" -maxdepth 1 -type f \( -name '*.flag' -o -name '*.log' \) -mtime +7 \
    ! -name "$CURRENT_SID"'_*' -delete 2>/dev/null
fi

exit 0
