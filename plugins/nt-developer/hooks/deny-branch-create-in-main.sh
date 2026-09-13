#!/usr/bin/env bash
# Bash の PreToolUse hook。ワークツリー運用の強制対象リポジトリの本体チェックアウトで、ブランチを新しく作る操作（`git switch -c` / `git checkout -b` / `gh issue develop --checkout`）を deny する。
#
# deny-worktree-for-edit.sh が見ているのはファイルを書き換える操作だけなので、本体にブランチを切る操作は素通りし、編集で初めて止まってそのぶん手戻りになる。

set -euo pipefail

# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"
# shellcheck source=lib-branch-create.sh
source "${BASH_SOURCE[0]%/*}/lib-branch-create.sh"
# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-effective-cwd.sh
source "${BASH_SOURCE[0]%/*}/lib-effective-cwd.sh"
# shellcheck source=lib-worktree-enforcement.sh
source "${BASH_SOURCE[0]%/*}/lib-worktree-enforcement.sh"

INPUT_JSON="$(cat)"

[[ "$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")" == "Bash" ]] || exit 0

COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -n "$COMMAND" ]] || exit 0

STRIPPED="$(strip_quoted "$COMMAND")"

# `--list` / `-l` は読み取りだけなので対象にしない。`--checkout` / `-c` を付けた形だけがローカルにブランチを作る。
GH_DEVELOP_RE="${BRANCH_CMD_HEAD}gh[[:space:]]+issue[[:space:]]+develop([[:space:]]+[^|;&]*)?[[:space:]](--checkout|-[[:alnum:]]*c)([[:space:]]|\$)"

matched=""
if is_branch_create_command "$STRIPPED"; then
  matched="git のブランチ作成"
elif grep -qE "$GH_DEVELOP_RE" <<<"$STRIPPED"; then
  matched="gh issue develop --checkout"
fi
[[ -n "$matched" ]] || exit 0

CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
[[ -n "$CWD" ]] || exit 0
TARGET_DIR="$(effective_cwd "$COMMAND" "$CWD")"

REPO_NAME="$(worktree_enforced_repo_name "$TARGET_DIR")"
[[ -n "$REPO_NAME" ]] || exit 0

is_main_checkout "$TARGET_DIR" || exit 0

REASON="🚫 ${REPO_NAME} は本体のチェックアウトにブランチを切らない運用だ（${matched} を検出した）。作業用のブランチはワークツリーの作成とまとめて作る。手順は Skill ツールで nt-developer:git-rules を起動して読め。"

emit_pretooluse_decision deny "$REASON"

exit 0
