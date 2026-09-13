#!/usr/bin/env bash
# Bash PreToolUse hook。orca worktree create に --agent が付いていたら ask する。
#
# --agent 付きの起動は、別プロセスの Claude がその場で実装からマージまで走り切る。
# --agent 無しは対象外にする（gate-branch-op-approval.sh の「ブランチ作成とワークツリーの作成を ask に足すな」と衝突させない）。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# shellcheck source=lib-git-command-category.sh
source "${BASH_SOURCE[0]%/*}/lib-git-command-category.sh"
# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

ORCA_WORKTREE_CREATE_RE="${GIT_CMD_HEAD}orca[[:space:]]+worktree[[:space:]]+create([[:space:]]|\$)"
AGENT_OPT_RE='(^|[[:space:]])--agent([[:space:]]|=|$)'

# --prompt の本文に --agent と書いただけで発火しないよう、クォートの中身を落とす
stripped="$(strip_quoted "$command")"

if ! grep -qE "$ORCA_WORKTREE_CREATE_RE" <<<"$stripped"; then
  exit 0
fi

if ! grep -qE "$AGENT_OPT_RE" <<<"$stripped"; then
  exit 0
fi

REASON="⚠️ --agent 付きの orca worktree create は、別の Claude がその場で実装からマージまで走り出す起動だ。実行前に確認しろ: 何をどう変えるかをユーザーに提示し、着手の承認を得たか。得ていないなら起動するな。まず Skill ツールで nt-developer:plan を起動し、計画を提示して承認を取れ。承認済みならその旨をユーザーへ伝えてこの確認を通せ。"
emit_pretooluse_decision ask "$REASON"
exit 0
