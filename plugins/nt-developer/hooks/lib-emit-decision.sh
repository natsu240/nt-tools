#!/usr/bin/env bash
# PreToolUse hook の応答 JSON を組み立てる処理。
#
# permissionDecisionReason を systemMessage にも複製する（前者だけだと画面に出ない）。

# 標準出力へ PreToolUse の応答 JSON を返す。
# 引数: $1=permissionDecision（allow/deny/ask） $2=permissionDecisionReason
emit_pretooluse_decision() {
  local decision="$1" reason="$2"
  jq -n --arg decision "$decision" --arg reason "$reason" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: $decision,
        permissionDecisionReason: $reason
      },
      systemMessage: $reason
    }
  '
}
