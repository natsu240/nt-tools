#!/usr/bin/env bash
# Agent(subagent_type: "fork") の直接起動を禁止する PreToolUse hook。
# context: fork を指定した SKILL.md 経由の fork 実行は Skill ツール呼び出しであり、ここで見ている Agent ツールの直接呼び出しとは別経路のため対象外になる。

input=$(cat)

subagent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""')
[ "$subagent_type" != "fork" ] && exit 0

reason=$(printf '%s\n' \
  "🚫 Agent(subagent_type: \"fork\") の直接起動は禁止。" \
  "   fork が必要なら SKILL.md に context: fork を指定したスキル経由で使え。")
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

exit 0
