#!/usr/bin/env bash
# Bash PreToolUse hook。
# base ブランチから新しいブランチを切ろうとしたとき、base が最新でなければ deny する。
#
# 古い base から切ると、直近でマージされた他の PR と衝突して rebase のやり直しになる。
#
# **遅れの判定より先に FETCH_HEAD の鮮度を見ろ。** fetch していない状態ではリモート追跡の情報自体が古く、遅れているかどうかを判定できない。

set -euo pipefail

FETCH_MAX_AGE_SECONDS=300

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# クォートの中身を落としてから判定する。コミットメッセージ本文に git switch -c と書いただけで止まるのを防ぐため。
# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

stripped="$(strip_quoted "$command")"

# shellcheck source=lib-branch-create.sh
source "${BASH_SOURCE[0]%/*}/lib-branch-create.sh"

if ! is_branch_create_command "$stripped"; then
  exit 0
fi

HOOK_CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
[[ -z "$HOOK_CWD" ]] && exit 0

# --absolute-git-dir で絶対パスを取る。--git-dir は相対パス（`.git`）を返すことがあり、hook 自身のカレントディレクトリから解決されて別のリポジトリの FETCH_HEAD を読んでしまう。
GIT_DIR="$(git -C "$HOOK_CWD" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
CURRENT_BRANCH="$(git -C "$HOOK_CWD" symbolic-ref --quiet --short HEAD 2>/dev/null)" || exit 0

# 今いるブランチが base ブランチかどうか。default ブランチ名は決め打ちせず origin/HEAD から取る。
DEFAULT_BRANCH="$(git -C "$HOOK_CWD" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [[ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" && "$CURRENT_BRANCH" != "develop" ]]; then
  exit 0
fi

# 追跡すべきリモートのブランチが無ければ判定材料が無い。
if ! git -C "$HOOK_CWD" rev-parse --verify --quiet "refs/remotes/origin/${CURRENT_BRANCH}" >/dev/null 2>&1; then
  exit 0
fi

respond_deny() {
  local reason="$1"
  jq -n --arg reason "$reason" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      },
      systemMessage: $reason
    }
  '
  exit 0
}

# FETCH_HEAD の更新時刻。stat のオプションは BSD（macOS）と GNU で違うので両方試す。
fetch_head="${GIT_DIR}/FETCH_HEAD"
if [[ ! -f "$fetch_head" ]]; then
  respond_deny "🚫 ${CURRENT_BRANCH} から新しいブランチを切る前に \`git fetch origin\` を実行してください。このリポジトリではまだ一度も fetch しておらず、ローカルの ${CURRENT_BRANCH} が最新かどうかを判定できません。"
fi

fetched_at="$(stat -c %Y "$fetch_head" 2>/dev/null || stat -f %m "$fetch_head" 2>/dev/null || echo 0)"
now="$(date +%s)"
age=$((now - fetched_at))

if [[ "$age" -ge "$FETCH_MAX_AGE_SECONDS" ]]; then
  respond_deny "🚫 ${CURRENT_BRANCH} から新しいブランチを切る前に \`git fetch origin\` を実行してください。最後に fetch したのは $((age / 60)) 分前で、ローカルの ${CURRENT_BRANCH} が最新かどうかを今の情報では判定できません。古い ${CURRENT_BRANCH} から切ると、直近でマージされた他の PR と衝突してやり直しになります。"
fi

behind="$(git -C "$HOOK_CWD" rev-list --count "HEAD..refs/remotes/origin/${CURRENT_BRANCH}" 2>/dev/null || echo 0)"
if [[ "$behind" -gt 0 ]]; then
  respond_deny "🚫 ローカルの ${CURRENT_BRANCH} が origin より ${behind} コミット遅れています。先に \`git pull --ff-only origin ${CURRENT_BRANCH}\` で最新化してからブランチを切ってください。未コミットの変更があるなら \`git stash push -u\` で退避してから pull してください。"
fi

exit 0
