#!/usr/bin/env bash
# research skill の PreToolUse hook。専用 MCP で直接読める情報源の URL が調査テーマに含まれていれば deny する。
#
# args は SKILL.md 冒頭の調査テーマにそのまま展開される本文だ。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Skill" ]] && exit 0

SKILL_NAME="$(jq -r '.tool_input.skill // empty' <<<"$INPUT_JSON")"
grep -qE '^(nt-common:)?research$' <<<"$SKILL_NAME" || exit 0

ARGS="$(jq -r '.tool_input.args // empty' <<<"$INPUT_JSON")"
[[ -z "$ARGS" ]] && exit 0

source_for_domain() {
  printf 'Google Workspace（mcp__plugin_nt-common_google-workspace__*）'
}

MCP_DOMAINS=(docs.google.com drive.google.com sheets.google.com)

for domain in "${MCP_DOMAINS[@]}"; do
  grep -qF -- "$domain" <<<"$ARGS" || continue
  REASON="🚫 調査テーマに ${domain} の URL が含まれている。この情報源は $(source_for_domain "$domain") の MCP ツールで直接読める。research へ丸投げせず、MCP ツールで直接取得しろ。"
  emit_pretooluse_decision deny "$REASON"
  exit 0
done

exit 0
