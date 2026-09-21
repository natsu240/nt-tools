#!/usr/bin/env bash
# Edit / MultiEdit / Write / ファイルを書き換える git 操作の Bash に対する PreToolUse hook。
# 本体の作業ツリー（git worktree で切り出したフォルダではない側）での変更を deny し、worktree へ誘導する。
#
# 対象リポジトリの一覧と本体／切り出した側の判定は lib-worktree-enforcement.sh にある。
#
# ブランチの移動・fetch・pull・マージ・worktree 操作は本体側で行う作業なので対象にしない。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"

# shellcheck source=lib-git-command-category.sh
source "${BASH_SOURCE[0]%/*}/lib-git-command-category.sh"
# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-effective-cwd.sh
source "${BASH_SOURCE[0]%/*}/lib-effective-cwd.sh"
# shellcheck source=lib-worktree-enforcement.sh
source "${BASH_SOURCE[0]%/*}/lib-worktree-enforcement.sh"

WRITE_GIT_OP_RE="${GIT_CMD_HEAD}git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(add|commit|push|rm|mv|reset|restore|clean|apply|cherry-pick|revert|stash)([[:space:]]|\$)"
GIT_C_DIR_RE="${GIT_CMD_HEAD}git[[:space:]]+-C[[:space:]]+[^[:space:];&|)]+"

# コマンドが `git -C <パス>` で操作先を明示していれば、そのパスを1行返す。クォートで囲まれていても拾う。
git_c_dir() {
  local command="$1" match
  match="$(grep -oE "$GIT_C_DIR_RE" <<<"$(unquote_command "$command")" | head -1 || true)"
  [[ -n "$match" ]] || return 1
  printf '%s' "${match##*[[:space:]]}"
}

TARGET_DIR=""
case "$TOOL_NAME" in
  Edit|MultiEdit|Write)
    TARGET_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
    [[ -z "$TARGET_PATH" ]] && exit 0
    TARGET_DIR="$(nearest_existing_dir "$TARGET_PATH")"
    if git -C "$TARGET_DIR" check-ignore -q -- "$TARGET_PATH" 2>/dev/null; then
      exit 0
    fi
    ;;
  Bash)
    COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
    [[ -z "$COMMAND" ]] && exit 0
    stripped="$(strip_quoted "$COMMAND")"
    if ! grep -qE "$WRITE_GIT_OP_RE" <<<"$stripped"; then
      exit 0
    fi
    if GIT_C_DIR="$(git_c_dir "$COMMAND")" && [[ -d "$GIT_C_DIR" ]]; then
      TARGET_DIR="$GIT_C_DIR"
    else
      TARGET_DIR="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
      [[ -z "$TARGET_DIR" ]] && exit 0
      TARGET_DIR="$(effective_cwd "$COMMAND" "$TARGET_DIR")"
    fi
    ;;
  *)
    exit 0
    ;;
esac

REPO_NAME="$(worktree_enforced_repo_name "$TARGET_DIR")"
[[ -n "$REPO_NAME" ]] || exit 0

is_main_checkout "$TARGET_DIR" || exit 0

BRANCH_NAME="$(git -C "$TARGET_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[[ -z "$BRANCH_NAME" ]] && BRANCH_NAME="<ブランチ名>"

REASON="🚫 ${REPO_NAME} はファイルを変更する作業を必ずワークツリーで行う運用だ（本体のフォルダは main の更新・PR のマージ・掃除にだけ使う）。作りかたと片付けかたは Skill ツールで nt-developer:git-rules を起動して読め。今のブランチは ${BRANCH_NAME} だ。"

emit_pretooluse_decision deny "$REASON"

exit 0
