#!/usr/bin/env bash
# Agent(team_name: "...") による Agent Teams の起動を禁止する PreToolUse hook。
# 一発勝負の並列調査には不要な協業専用の重い仕組みのため（詳細は agent-rules skill）。

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

input=$(cat)

team_name=$(printf '%s' "$input" | jq -r '.tool_input.team_name // ""')
[ -z "$team_name" ] && exit 0

reason=$(printf '%s\n' \
  "🚫 Agent(team_name: \"...\") による Agent Teams の起動は禁止。" \
  "   team_name を指定せず通常の Agent 呼び出しにしろ。複数の独立調査を並列に投げたいだけなら、1メッセージに複数の Agent 呼び出しを並べれば足りる（nt-common:agent-rules 参照）。")
emit_pretooluse_decision deny "$reason"
exit 0
