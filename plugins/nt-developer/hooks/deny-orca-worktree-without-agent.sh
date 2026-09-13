#!/usr/bin/env bash
# Bash PreToolUse hook。orca worktree create に --agent と --prompt が揃っていなければ deny する。
#
# 揃っていないとワークツリーだけができ、呼び出し元のセッションがそこへ移って実装するため、Orca のカードと実際に動いているセッションがズレる。

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
PROMPT_OPT_RE='(^|[[:space:]])--prompt([[:space:]]|=|$)'

stripped="$(strip_quoted "$command")"
if ! grep -qE "$ORCA_WORKTREE_CREATE_RE" <<<"$stripped"; then
  exit 0
fi

if grep -qE "$AGENT_OPT_RE" <<<"$stripped" && grep -qE "$PROMPT_OPT_RE" <<<"$stripped"; then
  exit 0
fi

REASON="🚫 orca worktree create に --agent と --prompt が揃っていない。ワークツリーだけ作って呼び出し元のセッションが自分で実装すると、Orca に子カードだけが並び、中で動いているセッションが1つも無い状態になる。--agent claude --prompt \"<引き継ぎ内容>\" を付けて、実装はワークツリーの中で起動する Claude に渡せ。引き継ぎ内容の書き方は Skill ツールで nt-developer:git-rules を起動して読め。"
emit_pretooluse_decision deny "$REASON"
exit 0
