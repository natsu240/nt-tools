#!/usr/bin/env bash
# Stop hook。Agent の呼び出しを応答本文へ印字しただけで実行しなかったターンを止める。
#
# 印字はツール呼び出しではないため PreToolUse は一切発火せず、他の Agent 起動規制も素通りする。
# assistant の本文を受け取れるイベントは Stop だけだ。

set -uo pipefail

INPUT_JSON="$(cat)"

# 印字した本文は同じターンの記録に残り続けるため、これを見ないと同じ理由で止め続ける（公式ドキュメントが案内しているループ防止手段）。
STOP_HOOK_ACTIVE="$(jq -r '.stop_hook_active // false' <<<"$INPUT_JSON")"
[[ "$STOP_HOOK_ACTIVE" == "true" ]] && exit 0

# メインループは agent_type="worker" かつ agent_id 未設定で来る。
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT_JSON")"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT_JSON")"
if [[ -n "$AGENT_ID" || ( -n "$AGENT_TYPE" && "$AGENT_TYPE" != "worker" ) ]]; then
  exit 0
fi

TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
LAST_MESSAGE="$(jq -r '.last_assistant_message // empty' <<<"$INPUT_JSON")"

# 人の発話は content が文字列で、tool_result は配列で入る。
TURN='[]'
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
  TURN="$(jq -s '
    . as $all
    | ([range(0; ($all | length))
        | select($all[.].type == "user" and (($all[.].message.content) | type == "string"))]
       | last // -1) as $i
    | $all[($i + 1):]
  ' <"$TRANSCRIPT_PATH" 2>/dev/null)"
  [[ -z "$TURN" ]] && TURN='[]'
fi

REAL_AGENT_CALLS="$(jq '
  [.[] | select(.type == "assistant") | .message.content[]?
   | select(.type == "tool_use" and .name == "Agent")] | length
' <<<"$TURN" 2>/dev/null)"
[[ "${REAL_AGENT_CALLS:-0}" != "0" ]] && exit 0

# 会話ログは書き込みが遅れてターン末尾の発言を含まないことがあるため、last_assistant_message も混ぜる。
TEXTS="$(jq -r '
  .[] | select(.type == "assistant") | .message.content[]?
  | select(.type == "text") | .text
' <<<"$TURN" 2>/dev/null)"
TEXTS="$(printf '%s\n%s' "$TEXTS" "$LAST_MESSAGE")"

BACKTICK='`'
# 説明として引用した呼び出しを止めないため、囲みコードブロックとインラインコードを落とす。シェルのクォート除去と同じ処理は使えない（markdown の囲みは行単位の別物）。
# バッククォートを変数へ出すのは、bash 3.2（macOS 同梱）が $( ) の中の単一引用符でバッククォートを保護できないため。
BARE_TEXTS="$(printf '%s\n' "$TEXTS" | awk -v bt="$BACKTICK" '
  $0 ~ "^[[:space:]]*(" bt bt bt "|~~~)" { fence = 1 - fence; next }
  fence { next }
  { gsub(bt "[^" bt "]*" bt, ""); print }
')"

if ! grep -qE '^Agent\((\{|[[:space:]]*$)' <<<"$BARE_TEXTS"; then
  exit 0
fi

REASON="$(printf '%s\n' \
  '🚫 Agent の呼び出しを応答本文へ印字しただけで、ツールとしては実行していません。' \
  '   サブエージェントは起動しておらず結果も存在しません。起動したかのように書いたなら訂正しろ。' \
  '   本当に必要なら Agent ツールを実際に呼べ。ファイルを読むだけの用途なら委譲せず自分で読め。' \
  '   Agent(subagent_type: "fork") の直接起動は禁止だ。fork が必要なら SKILL.md に context: fork を指定したスキル経由で使え。')"

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'

exit 0
