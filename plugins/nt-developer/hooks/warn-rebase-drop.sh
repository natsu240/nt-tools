#!/usr/bin/env bash
# git rebase の PreToolUse hook。GIT_SEQUENCE_EDITOR でコミットを drop する形を、git show による確認が無ければ deny にする。
#
# drop 指定の判定はクォートを落とす前の文字列で行う。`GIT_SEQUENCE_EDITOR="sed -i ..."` のようにクォートの中へ書くため、落とすと検出そのものが成立しない。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$COMMAND" ]] && exit 0

grep -qE 'git[[:space:]]+rebase' <<<"$COMMAND" || exit 0
grep -qF 'GIT_SEQUENCE_EDITOR' <<<"$COMMAND" || exit 0
grep -qE '\bdrop\b' <<<"$COMMAND" || exit 0

TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
[[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] || exit 0

bash_commands="$(
  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | .input.command // empty
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true
)"
grep -qE 'git[[:space:]]+show' <<<"$bash_commands" && exit 0

REASON="🚫 rebase でコミットを drop しようとしているが、このセッションで \`git show <hash> --stat\` 等によるコミット内容の確認を一度も実行していない。drop する前にそのコミットの実際の差分を確認しろ。コミットメッセージやファイル名が似ているという理由だけで「取り込み済みと重複」と判断するな。他者のコミットが対象なら特に危ない。"
emit_pretooluse_decision deny "$REASON"

exit 0
