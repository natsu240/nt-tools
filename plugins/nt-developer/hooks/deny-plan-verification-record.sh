#!/usr/bin/env bash
# 計画へ「確認テスト: 合格」を書き込む操作に効く PreToolUse hook。
# 「該当した観点」に並ぶ断定文1件ごとに、その文を含む AskUserQuestion が実際に投げられているかを突き合わせ、対応する質問が無い断定文が1件でもあれば deny する。
#
# 対象は計画の書き込み先だけだ（gh issue edit / create の description と、plans 配下のファイル）。
# 提示を行うのは計画セッションなので、保存済みの計画を読む deny-plan-decision-gate.sh 側にこの判定を足すな。実装セッション・レビューセッションの会話ログには提示が無く、後続のセッションで必ず誤って止まる。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-ask-questions.sh
source "${BASH_SOURCE[0]%/*}/lib-ask-questions.sh"
# shellcheck source=lib-plan-file-path.sh
source "${BASH_SOURCE[0]%/*}/lib-plan-file-path.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"

# gh issue edit / create で description を渡すコマンドなら 0 を返す。
is_issue_body_command() {
  local command="$1"
  grep -qE '(^|[[:space:];&|])gh[[:space:]]+issue[[:space:]]+(edit|create)([[:space:]]|$)' <<<"$command" || return 1
  grep -qE '[[:space:]]--body(-file)?([[:space:]]|=|$)' <<<"$command"
}

# --body-file に渡されたパスの中身をコマンド文字列へ足す。
append_body_files() {
  local command="$1" haystack="$1" path paths
  paths="$(grep -oE -- '--body-file[= ]+"?[^"[:space:]]+"?' <<<"$command" | sed -E 's/^--body-file[= ]+//; s/"//g' || true)"
  while IFS= read -r path; do
    [[ -n "$path" && -f "$path" ]] || continue
    haystack+=$'\n'"$(cat "$path")"
  done <<<"$paths"
  printf '%s' "$haystack"
}

issue_body_before() {
  local command="$1" number
  number="$(grep -oE '(^|[[:space:];&|])gh[[:space:]]+issue[[:space:]]+edit[[:space:]]+[0-9]+' <<<"$command" | grep -oE '[0-9]+$' || true)"
  [[ -n "$number" ]] || return 0
  gh issue view "$number" --json body --jq .body 2>/dev/null || true
}

assertion_of_line() {
  printf '%s' "$1" \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' \
    | sed -E 's/^[^:：]*[:：][[:space:]]*//' \
    | sed -E 's/^(.*)—.*$/\1/'
}

HAYSTACK=""
BEFORE=""

case "$TOOL_NAME" in
  Bash)
    COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
    is_issue_body_command "$COMMAND" || exit 0
    HAYSTACK="$(append_body_files "$COMMAND")"
    BEFORE="$(issue_body_before "$COMMAND")"
    ;;
  Write)
    FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
    is_plan_file_path "$FILE_PATH" || exit 0
    HAYSTACK="$(jq -r '.tool_input.content // empty' <<<"$INPUT_JSON")"
    [[ -f "$FILE_PATH" ]] && BEFORE="$(cat "$FILE_PATH")"
    ;;
  Edit|MultiEdit)
    FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
    is_plan_file_path "$FILE_PATH" || exit 0
    HAYSTACK="$(jq -r '[.tool_input.new_string // empty, (.tool_input.edits[]?.new_string // empty)] | join("\n")' <<<"$INPUT_JSON")"
    [[ -f "$FILE_PATH" ]] && BEFORE="$(cat "$FILE_PATH")"
    ;;
  *)
    exit 0
    ;;
esac

grep -qF '確認テスト: 合格' <<<"$HAYSTACK" || exit 0

is_applicable_header() {
  local bare="${1//[[:space:]]/}"
  bare="${bare//[#*_:]/}"
  [[ "$bare" == "該当した観点" || "$bare" == "該当した観点：" ]]
}

ASSERTION_LINES="$(awk '
  { bare = $0; gsub(/[[:space:]#*_:]/, "", bare) }
  bare ~ /^該当した観点：?$/ { inblock = 1; next }
  inblock && (bare ~ /^該当なしと判定した観点：?$/ || /確認テスト: 合格/ || /^#/) { inblock = 0 }
  inblock && /^[[:space:]]*[-*][[:space:]]/ { print }
' <<<"$HAYSTACK")"

HAS_APPLICABLE_HEADER=false
while IFS= read -r line; do
  is_applicable_header "$line" || continue
  HAS_APPLICABLE_HEADER=true
  break
done <<<"$HAYSTACK"

BEFORE_NORMALIZED="$(normalize_for_match "$BEFORE")"

NEW_ASSERTIONS=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  normalized="$(normalize_for_match "$(assertion_of_line "$line")")"
  [[ -n "$normalized" ]] || continue
  grep -qF -- "$normalized" <<<"$BEFORE_NORMALIZED" && continue
  NEW_ASSERTIONS+="$line"$'\n'
done <<<"$ASSERTION_LINES"

if [[ -z "${NEW_ASSERTIONS//[$'\n']/}" ]] && grep -qF '確認テスト: 合格' <<<"$BEFORE"; then
  exit 0
fi

if [[ "$HAS_APPLICABLE_HEADER" != true ]]; then
  REASON="🚫 「確認テスト: 合格」を書き込む操作に「該当した観点」の一覧が含まれていない。合格の1行だけを後から足すな。plan skill の確認テスト手順（該当する観点だけを断定文にして1件ずつ AskUserQuestion で提示する）を行い、該当した観点の一覧ごと同じ書き込みに含めて再試行しろ。"
  emit_pretooluse_decision deny "$REASON"
  exit 0
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"

QUESTIONS_NORMALIZED=""
while IFS= read -r question; do
  [[ -n "$question" ]] || continue
  QUESTIONS_NORMALIZED+="$(normalize_for_match "$question")"$'\n'
done <<<"$(collect_ask_questions "$SESSION_ID" "$TRANSCRIPT_PATH")"

MISSING=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  assertion="$(assertion_of_line "$line")"
  normalized="$(normalize_for_match "$assertion")"
  grep -qF -- "$normalized" <<<"$QUESTIONS_NORMALIZED" && continue
  MISSING+="・${assertion}"$'\n'
done <<<"$NEW_ASSERTIONS"

if [[ -n "$MISSING" ]]; then
  REASON="🚫 計画に書いた確認テストの断定文のうち、AskUserQuestion で提示されていないものがある。次の断定文を1件ずつ AskUserQuestion で提示してから再試行しろ。質問文には計画へ書く断定文をそのまま使え。言い換えると突き合わせられない。
${MISSING}"
  emit_pretooluse_decision deny "$REASON"
  exit 0
fi

exit 0
