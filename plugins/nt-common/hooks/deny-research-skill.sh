#!/usr/bin/env bash
# WebFetch / WebSearch の PreToolUse hook。/research を経由せずに外部情報を取りに行くのを deny する。

set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
case "$TOOL_NAME" in
  WebFetch|WebSearch) ;;
  *) exit 0 ;;
esac

# サブエージェント配下からの呼び出しは素通り（メインループのみ block 対象）。
# Claude Code 2.1.x の PreToolUse payload には共通フィールドとしてagent_id / agent_type が乗る（バイナリ内部関数 v3 / kV で構築）。
# メインスレッドは agent_type="worker" でかつ agent_id 非設定、サブエージェントは agent_id 非空かつ agent_type は固有の型名。
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT_JSON")"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT_JSON")"
if [[ -n "$AGENT_ID" || ( -n "$AGENT_TYPE" && "$AGENT_TYPE" != "worker" ) ]]; then
  exit 0
fi

if [[ -n "${NT_RESEARCH_SUBPROCESS:-}" ]]; then
  exit 0
fi

TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# 「本物のユーザー発話」判定条件（tool_result/local-command/system-reminder 等は除外）。
# AskUserQuestion の回答等、message.content が配列型のものはここでは対象外（ターン区切りの厳密さより「一連のタスク中の累積呼び出し回数」を優先するため）。
USER_FILTER='
  select(.type == "user")
  | select((.message.content // empty) | type == "string")
  | select((.message.content) | test("^<(local-command|command-(name|message|args|stdout)|system-reminder|tool_use_)") | not)
'

# 直近の「本物のユーザー発話」だけを抽出
RECENT_USER_TEXT="$(
  jq -r "$USER_FILTER | .message.content" <"$TRANSCRIPT_PATH" 2>/dev/null \
    | tail -n 10 \
    | tr '\n' ' '
)"

KEYWORDS_RE='調査|調べて|徹底|確認して|research|一次ソース|verbatim|公式|本当か|まじ|裏取|裏付|事実確認|真偽'

DENY_REASON=""

if printf '%s' "$RECENT_USER_TEXT" | grep -E -q "$KEYWORDS_RE"; then
  DENY_REASON='🚫 徹底調査の文脈が検出されたため、WebFetch/WebSearch の直叩きを禁止しました。

外部情報の調査・事実確認・裏取りが必要なら、まず Skill ツールで `nt-common:research`(/research) を起動しろ。一次ソース取得・出典管理・スニペット禁止のフローはその中で実施される。

WebSearch の結果スニペットは「URL を見つける索引」であって一次ソースではない。事実として書くなら WebFetch で本文を取得しろ。記憶・推測で書くしかない場合は、文中に「記憶ベース」「推測」「未確認」のいずれかを必ず明示しろ。

もしこれが徹底調査ではない軽量確認（1ファイル Read 相当）であれば、ユーザーに「/research 起動不要か」を明示確認してから再試行しろ。'
fi

# 回数ベースの検出: キーワードが無くても、直近の本物のユーザー発話以降（今回の呼び出しを含めて）3 回目以降の WebFetch/WebSearch は deny する。
if [[ -z "$DENY_REASON" ]]; then
  LAST_USER_TS="$(jq -r "$USER_FILTER | .timestamp" <"$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)"

  if [[ -n "$LAST_USER_TS" ]]; then
    PRIOR_FETCH_COUNT="$(
      jq -c --arg ts "$LAST_USER_TS" '
        select(.type == "assistant")
        | select(.timestamp > $ts)
        | (.message.content // [])[]?
        | select(.type == "tool_use")
        | select(.name == "WebFetch" or .name == "WebSearch")
      ' <"$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' '
    )"
  else
    PRIOR_FETCH_COUNT=0
  fi

  THIS_CALL_COUNT=$((PRIOR_FETCH_COUNT + 1))
  THRESHOLD=3

  if (( THIS_CALL_COUNT >= THRESHOLD )); then
    DENY_REASON="🚫 直近のユーザー発話以降、WebFetch/WebSearch を ${THIS_CALL_COUNT} 回目呼び出そうとしたため禁止しました（キーワード未検出でも回数閾値 ${THRESHOLD} 回に到達）。

同じ調査を自前 WebFetch/WebSearch の繰り返しで行っている可能性がある。まず Skill ツールで \`nt-common:research\`(/research) を起動し、一次ソース取得・出典管理をそちらのフローに任せろ。

WebSearch の結果スニペットは「URL を見つける索引」であって一次ソースではない。事実として書くなら WebFetch で本文を取得しろ。記憶・推測で書くしかない場合は、文中に「記憶ベース」「推測」「未確認」のいずれかを必ず明示しろ。

もし本当に軽量な個別確認の繰り返しであれば、ユーザーに「/research 起動不要か」を明示確認してから再試行しろ。"
  fi
fi

if [[ -n "$DENY_REASON" ]]; then
  emit_pretooluse_decision deny "$DENY_REASON"
fi

exit 0
