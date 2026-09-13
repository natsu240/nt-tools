#!/usr/bin/env bash
# git commit の PreToolUse hook。直前の git add が失敗していたら deny にする。
#
# ステージが部分的に失敗したまま commit すると、意図した変更の一部が落ちたコミットが出来上がる。失敗は会話ログの tool_result の is_error に残る。

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
[[ "$(git_command_category "$COMMAND")" == "commit" ]] || exit 0

TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
[[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] || exit 0

GIT_ADD_RE="${GIT_CMD_HEAD}git[[:space:]]+add([[:space:]]|\$)"

last_add_id=""
while IFS=' ' read -r tool_use_id encoded; do
  [[ -z "$tool_use_id" || -z "$encoded" ]] && continue
  decoded="$(printf '%s' "$encoded" | base64 -d 2>/dev/null || printf '%s' "$encoded" | base64 -D 2>/dev/null || true)"
  [[ -z "$decoded" ]] && continue
  if grep -qE "$GIT_ADD_RE" <<<"$(strip_quoted "$decoded")"; then
    last_add_id="$tool_use_id"
  fi
done < <(
  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | (.id // "-") + " " + ((.input.command // "") | @base64)
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true
)

[[ -z "$last_add_id" ]] && exit 0

FAILED_TOOL_USE_IDS="$(
  jq -r '
    select(.type == "user")
    | .message.content[]?
    | select(.type == "tool_result")
    | select(.is_error == true)
    | .tool_use_id // empty
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true
)"

grep -qxF -- "$last_add_id" <<<"$FAILED_TOOL_USE_IDS" || exit 0

REASON="🚫 直前の git add は失敗している。このままコミットすると、意図した変更の一部が落ちたコミットになる。git status / git diff --cached で、ステージされた内容が意図した対象と一致しているか確認してから進めろ。"
emit_pretooluse_decision deny "$REASON"

exit 0
