#!/usr/bin/env bash
# Agent(subagent_type: "fork") の直接起動を禁止する PreToolUse hook。
# context: fork を指定した SKILL.md 経由の fork 実行は Skill ツール呼び出しであり、ここで見ている Agent ツールの直接呼び出しとは別経路のため対象外になる。

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

input=$(cat)

subagent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""')
[ "$subagent_type" != "fork" ] && exit 0

reason=$(printf '%s\n' \
  "🚫 Agent(subagent_type: \"fork\") の直接起動は禁止。" \
  "   fork が必要なら SKILL.md に context: fork を指定したスキル経由で使え。")
emit_pretooluse_decision deny "$reason"
exit 0
