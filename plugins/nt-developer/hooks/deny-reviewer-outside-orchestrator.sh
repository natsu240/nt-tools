#!/usr/bin/env bash
# nt-developer:reviewer は code-review 専用の内部実装。
# review-orchestrator 以外（メインループ直叩き・他スキル経由含む）からの起動を block する。単体のコード調査目的での誤用を防ぐ。

input=$(cat)

subagent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""')
[ "$subagent_type" != "nt-developer:reviewer" ] && exit 0

caller_agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')
if [ "$caller_agent_type" != "nt-developer:review-orchestrator" ]; then
  reason=$(printf '%s\n' \
    "🚫 nt-developer:reviewer は code-review 専用の内部実装。呼び出し元 agent_type=\"$caller_agent_type\"（review-orchestrator 以外）からの起動は禁止。" \
    "   単体のコード調査は nt-common:explorer を使え。レビューがしたいなら /code-review スキルを使い review-orchestrator に任せろ。")
  jq -n --arg msg "$reason" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $msg
      },
      systemMessage: $msg
    }
  '
fi

exit 0
