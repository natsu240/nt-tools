#!/usr/bin/env bash
# Read の PostToolUse hook。読んだファイルのパスを目印に追記するだけ。
#
# この記録が要るのは、会話ログへの書き込みが PreToolUse の実行に間に合わず、Read 直後の編集を「まだ読んでいない」と誤判定するため。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
if [[ "$TOOL_NAME" != "Read" ]]; then
  exit 0
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
if [[ -z "$SESSION_ID" || -z "$FILE_PATH" ]]; then
  exit 0
fi

state_dir="$HOME/.claude/hook-state"
mkdir -p "$state_dir" 2>/dev/null
printf '%s\n' "$FILE_PATH" >>"$state_dir/${SESSION_ID}_reads.log" 2>/dev/null

exit 0
