#!/usr/bin/env bash
# Skill の PostToolUse hook。起動された skill 名を目印に追記するだけ。
#
# この記録が要るのは、会話ログへの書き込みが PreToolUse の実行に間に合わず、skill 起動直後の操作を誤って deny するため。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
if [[ "$TOOL_NAME" != "Skill" ]]; then
  exit 0
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
SKILL_NAME="$(jq -r '.tool_input.skill // empty' <<<"$INPUT_JSON")"
if [[ -z "$SESSION_ID" || -z "$SKILL_NAME" ]]; then
  exit 0
fi

state_dir="$HOME/.claude/hook-state"
mkdir -p "$state_dir" 2>/dev/null
printf '%s\n' "$SKILL_NAME" >>"$state_dir/${SESSION_ID}_skills.log" 2>/dev/null

exit 0
