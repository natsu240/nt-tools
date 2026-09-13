#!/usr/bin/env bash
# Agent ツールの PreToolUse hook。
# メインループが Agent (サブエージェント) に「外部ウェブの一次ソース調査」を丸投げすることで、WebFetch/WebSearch の直叩き規制を迂回するケースを検知し、deny する。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
if [[ "$TOOL_NAME" != "Agent" ]]; then
  exit 0
fi

# メインループ以外（サブエージェント配下からの Agent 呼び出し）は対象外。
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT_JSON")"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT_JSON")"
if [[ -n "$AGENT_ID" || ( -n "$AGENT_TYPE" && "$AGENT_TYPE" != "worker" ) ]]; then
  exit 0
fi

# claude-code-guide は Claude Code 自体の機能・仕様の質問専用に許可されたエージェント（CLAUDE.md のスキル自動起動マトリクスで明示指定）。
# WebFetch/WebSearch を使う設計そのものが目的なので、迂回とはみなさず素通りする。
SUBAGENT_TYPE="$(jq -r '.tool_input.subagent_type // empty' <<<"$INPUT_JSON")"
if [[ "$SUBAGENT_TYPE" == "claude-code-guide" ]]; then
  exit 0
fi

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

PROMPT_TEXT="$(jq -r '.tool_input.prompt // empty' <<<"$INPUT_JSON")"
DESC_TEXT="$(jq -r '.tool_input.description // empty' <<<"$INPUT_JSON")"
COMBINED_TEXT="${PROMPT_TEXT} ${DESC_TEXT}"

# A: 真偽確認・調査意図のキーワード
KEYWORDS_A='調査|確認して|真偽|裏取|裏付|事実確認|本当か|実在するか|実在するのか|徹底'
# B: 外部ウェブを指すキーワード（「一次ソース」はソースコードも指す語なので入れるな）
KEYWORDS_B='公式ドキュメント|公式サイト|公式ブログ|WebFetch|WebSearch|ウェブ検索|Web検索|ウェブで|GitHubリポジトリ|ブログ記事'
KEYWORDS_EXEMPT='Google Drive|スプレッドシート|Sheets|ローカルファイル|ローカルのファイル|リポジトリ内|リポジトリ配下|コードベース'
KEYWORDS_EXTERNAL_TOOL='WebFetch|WebSearch|外部URL|外部ウェブ|外部サイト|ウェブ検索|Web検索'
KEYWORDS_PROHIBITION='使うな|使用するな|使用禁止|使わない|使わず|禁止|行うな|するな|しないで|アクセスするな|なしで|不要'

declares_no_external_access() {
  local line
  while IFS= read -r line; do
    if grep -qE -- "$KEYWORDS_EXTERNAL_TOOL" <<<"$line" \
      && grep -qE -- "$KEYWORDS_PROHIBITION" <<<"$line"; then
      return 0
    fi
  done <<<"$1"
  return 1
}

if grep -qE -- "$KEYWORDS_A" <<<"$COMBINED_TEXT" \
  && grep -qE -- "$KEYWORDS_B" <<<"$COMBINED_TEXT" \
  && ! grep -qE -- "$KEYWORDS_EXEMPT" <<<"$COMBINED_TEXT" \
  && ! declares_no_external_access "$COMBINED_TEXT"; then
  emit_pretooluse_decision deny "🚫 外部ウェブの一次ソース調査をサブエージェントに丸投げしようとしているため禁止しました。

WebFetch/WebSearch のメインループ直叩きを塞ぐ規制があるが、Agent 経由でサブエージェントに投げると同じ規制を迂回できてしまう。外部情報の調査・真偽確認・一次ソース取得が目的なら、まず Skill ツールで \`nt-common:research\`(/research) を起動しろ。

もしこれが外部ウェブ調査ではない（コード調査・共有ドキュメント調査等）のに誤検知したのであれば、委譲プロンプトに次のどちらかを明記して再試行しろ。どちらが入っていてもこの hook は素通しする。自己判断で「誤検知だから」と別の手段へ迂回するな。

- 共有ドキュメントを読むなら、実際に触るツール名（Google Drive / スプレッドシート 等）
- ローカルのコードを読むだけなら、「ローカルファイルのみ」「リポジトリ内」「リポジトリ配下」のいずれか"
fi

exit 0
