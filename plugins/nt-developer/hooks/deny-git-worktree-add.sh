#!/usr/bin/env bash
# Bash PreToolUse hook。git worktree add を deny し、git-rules skill へ誘導する。
#
# --detach だけは通す。Orca は必ずブランチを作るため、README / CLAUDE.md だけの main 直 push を代替できない。

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

WORKTREE_ADD_RE="${GIT_CMD_HEAD}git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)*worktree[[:space:]]+add([[:space:]]|\$)"

stripped="$(strip_quoted "$command")"
if ! grep -qE "$WORKTREE_ADD_RE" <<<"$stripped"; then
  exit 0
fi

if grep -qE '(^|[[:space:]])--detach([[:space:]]|=|$)' <<<"$stripped"; then
  exit 0
fi

REASON="🚫 git worktree add で作ったワークツリーには Claude が入らず、Orca のカードと実体がズレる。ワークツリーは orca worktree create で作れ。手順は Skill ツールで nt-developer:git-rules を起動して読め。"
emit_pretooluse_decision deny "$REASON"
exit 0
