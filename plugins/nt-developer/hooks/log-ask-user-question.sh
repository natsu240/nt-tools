#!/usr/bin/env bash
# AskUserQuestion の PostToolUse hook。投げた質問文を目印に追記するだけ。
#
# この記録が要るのは、会話ログへの書き込みが PreToolUse の実行に間に合わず、直前に投げた質問が会話ログ側にまだ現れないため。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
if [[ "$TOOL_NAME" != "AskUserQuestion" ]]; then
  exit 0
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

QUESTIONS="$(jq -r '
  .tool_input.questions[]?
  | .question // empty
  | gsub("[\\n\\r\\t]"; " ")
  | select(. != "")
' <<<"$INPUT_JSON" 2>/dev/null || true)"

if [[ -z "$QUESTIONS" ]]; then
  exit 0
fi

state_dir="$HOME/.claude/hook-state"
mkdir -p "$state_dir" 2>/dev/null
printf '%s\n' "$QUESTIONS" >>"$state_dir/${SESSION_ID}_ask-questions.log" 2>/dev/null

exit 0
