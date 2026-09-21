#!/usr/bin/env bash
# PreToolUse hook の応答 JSON を組み立てる処理。
#
# permissionDecisionReason は画面に出ず、複数 hook が deny しても最初の1件しかモデルへ渡らないため、deny / ask では systemMessage と additionalContext（全 hook 分が連結して渡る）にも複製する。

# 標準出力へ PreToolUse の応答 JSON を返す。
# 引数: $1=permissionDecision（allow/deny/ask） $2=permissionDecisionReason
emit_pretooluse_decision() {
  local decision="$1" reason="$2"
  jq -n --arg decision "$decision" --arg reason "$reason" '
    {
      hookSpecificOutput: (
        {
          hookEventName: "PreToolUse",
          permissionDecision: $decision,
          permissionDecisionReason: $reason
        }
        + (if $decision == "allow" then {} else { additionalContext: $reason } end)
      ),
      systemMessage: $reason
    }
  '
}
