#!/usr/bin/env bash
# Bash PreToolUse hook。
# `gh pr create` に --assignee (-a) が付いていなければ deny する。
#
# 判定は gh pr create に限定する。初回作成時の取りこぼしだけが問題なので、既存 PR を編集する `gh pr edit --add-assignee` は対象にしない。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

stripped="$(strip_quoted "$command")"

CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z0-9_.-]*/)*'
PR_CREATE_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)"

grep -qE "$PR_CREATE_RE" <<<"$stripped" || exit 0

if grep -qE '(--assignee[[:space:]=]|-a[[:space:]])' <<<"$command"; then
  exit 0
fi

REASON='🚫 gh pr create に --assignee (-a) が付いていません。/pr スキルの規約では常に --assignee @me を付けます。--assignee @me を足して実行し直してください。'

emit_pretooluse_decision deny "$REASON"
exit 0
