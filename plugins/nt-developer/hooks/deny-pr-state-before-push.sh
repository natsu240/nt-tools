#!/usr/bin/env bash
# git push の PreToolUse hook。直近のユーザー発言以降に PR の state を個別確認していなければ deny にする（ask は bypassPermissions のセッションで自動通過する）。
#
# `gh pr list --state open` の検索結果だけでは、使い回しのブランチに紐づく MERGED 済みの PR を「継続中の PR」と取り違える。
# `-u` / `--set-upstream` 付きは新規ブランチの初回 push で、既存 PR の誤認が起きようがないため対象外。

set -euo pipefail

# shellcheck source=lib-git-command-category.sh
source "${BASH_SOURCE[0]%/*}/lib-git-command-category.sh"
# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$COMMAND" ]] && exit 0

STRIPPED="$(strip_quoted "$COMMAND")"
GIT_PUSH_RE="${GIT_CMD_HEAD}git[[:space:]]+push([[:space:]]|\$)"
grep -qE "$GIT_PUSH_RE" <<<"$STRIPPED" || exit 0
grep -qE '(^|[[:space:]])(-u|--set-upstream)([[:space:]]|$)' <<<"$STRIPPED" && exit 0

CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
if [[ -n "$CWD" && -d "$CWD" ]]; then
  BRANCH="$(git -C "$CWD" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -n "$BRANCH" ]]; then
    PR_COUNT="$(gh pr list --head "$BRANCH" --state all --json number --jq 'length' 2>/dev/null || true)"
    [[ "$PR_COUNT" == "0" ]] && exit 0
  fi
fi

TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
[[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] || exit 0

PR_STATE_CHECK_RE='gh[[:space:]]+pr[[:space:]]+view[^|;&]*state'

# 会話ログを1行1イベントに落とす。USER は人の発言（tool_result は .content が配列なので混ざらない）。
events=()
while IFS= read -r line; do
  [[ -n "$line" ]] && events+=("$line")
done < <(
  jq -r '
    if .type == "user" and (.message.content | type == "string") then "USER"
    elif .type == "assistant" then
      (.message.content[]? | select(.type == "tool_use" and .name == "Bash") | "CMD " + ((.input.command // "") | @base64))
    else empty end
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true
)

checked=0
i=$(( ${#events[@]} - 1 ))
while [[ "$i" -ge 0 ]]; do
  event="${events[$i]}"
  i=$((i - 1))
  [[ "$event" == "USER" ]] && break
  [[ "$event" == CMD\ * ]] || continue
  encoded="${event#CMD }"
  decoded="$(printf '%s' "$encoded" | base64 -d 2>/dev/null || printf '%s' "$encoded" | base64 -D 2>/dev/null || true)"
  if grep -qE "$PR_STATE_CHECK_RE" <<<"$(strip_quoted "$decoded")"; then
    checked=1
    break
  fi
done

[[ "$checked" -eq 1 ]] && exit 0

REASON="🚫 push しようとしているが、このターンで PR の state を個別に確認していない。\`gh pr view <番号> --json state\` で確認してから再実行しろ。ブランチが使い回されている場合、\`gh pr list --state open\` の検索結果だけで「既存 PR の続き」と判断するとマージ済みの PR を誤認する。新規 PR を立てるのか既存 PR に積むのか迷うなら、push の前にユーザーへ確認しろ。"
emit_pretooluse_decision deny "$REASON"

exit 0
