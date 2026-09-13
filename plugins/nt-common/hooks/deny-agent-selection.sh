#!/usr/bin/env bash
# **deny に例外を足すな。** 代替できない理由があっても通さない。

set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
if [[ "$TOOL_NAME" != "Agent" ]]; then
  exit 0
fi

SUBAGENT_TYPE="$(jq -r '.tool_input.subagent_type // empty' <<<"$INPUT_JSON")"
NORMALIZED_TYPE="$(tr '[:upper:]' '[:lower:]' <<<"$SUBAGENT_TYPE")"

case "$NORMALIZED_TYPE" in
  ""|claude|general-purpose|explore)
    REASON="$(jq -n -r --arg t "$SUBAGENT_TYPE" '
      "🚫 subagent_type=\"" + $t + "\" での Agent 起動は禁止。広範なコードベース調査は nt-common:explorer、その他のタスクも専用エージェント一覧から選び直せ。claude / general-purpose / Explore / 未指定は、メインループでもサブエージェント配下でも例外なく使用不可。"
    ')"
    emit_pretooluse_decision deny "$REASON"
    ;;
esac

exit 0
