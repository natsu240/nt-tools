#!/usr/bin/env bash
set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
if [[ "$TOOL_NAME" != "Agent" ]]; then
  exit 0
fi

SUBAGENT_TYPE="$(jq -r '.tool_input.subagent_type // empty' <<<"$INPUT_JSON")"

case "$SUBAGENT_TYPE" in
  "Explore")
    emit_pretooluse_decision allow "🚫 subagent_type=\"Explore\" は使うな。広範なコードベース調査・地図調査は代わりに subagent_type=\"nt-common:explorer\" を使え。"
    ;;
  "nt-common:skimmer")
    emit_pretooluse_decision allow "⚠️ skimmer 起動を検知。投げる前に対象を確認しろ。

❌ skimmer 対象外（原文のまま必要なので親で Read）:
- PR レビューコメント・PR description（指摘内容・意図の判定根拠）
- 仕様書本文・公式ドキュメント（仕様判定の根拠）
- コードレビュー対象の本文

✅ skimmer 対象:
- git diff/log の機械的要約
- 大量ログファイル・大きい API レスポンス
- 長文ドキュメントの「空気読み」要約（事実判定の根拠にしない前提）

要約に丸めた瞬間に否定形・限定条件・時制が落ちる。判定根拠なら親で gh pr view / Read を直接叩け。"
    ;;
  *)
    # "" (未指定) も含めそれ以外は素通り
    exit 0
    ;;
esac

exit 0
