#!/usr/bin/env bash
# Bash PreToolUse hook。
# マージを permissionDecision: ask に落とし、未コミットの変更を抱えたままの`git pull` は deny する。
#
# PR 番号を省略した `gh pr merge` を deny に含めているのは、暗黙のカレントブランチが対象になると `--delete-branch` 併用時に実行後どの PR だったか特定し直せなくなるため。
#
# **ブランチ作成とワークツリーの作成を ask に足すな。** 作業のたびに必ず通る操作なので毎回確認が入る一方、間違えても切り直すだけで履歴も作業内容も壊れない。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# クォートの中身を落としてから判定する。コミットメッセージ本文に git merge と書いただけで確認が出るのを防ぐため。
# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

stripped="$(strip_quoted "$command")"

CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z0-9_.-]*/)*'
MERGE_RE="${CMD_HEAD}git[[:space:]]+merge([[:space:]]|\$)"
PR_MERGE_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|\$)"
PULL_RE="${CMD_HEAD}git[[:space:]]+pull([[:space:]]|\$)"

# 確認を挟まないリポジトリは project_notes/automation.md にこのマーカー行を置いて申告する。無ければ確認する側に倒れる。
EXEMPT_MARKER_RE='^[[:space:]]*claude-merge-approval:[[:space:]]*skip[[:space:]]*$'

# 作業中のリポジトリがマーカー行を持つなら 0 を返す
is_exempt_repo() {
  local dir="$1" common notes
  [[ -z "$dir" ]] && return 1
  # --show-toplevel はワークツリーのフォルダを返す。project_notes/ は本体にしか置かれないため、共通の .git を持つ本体のディレクトリを見る。
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  notes="$(dirname "$common")/project_notes/automation.md"
  [[ -f "$notes" ]] || return 1
  grep -qE "$EXEMPT_MARKER_RE" "$notes"
}

HOOK_CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"

respond() {
  local decision="$1"
  local reason="$2"
  emit_pretooluse_decision "$decision" "$reason"
  exit 0
}

# grep へは here-string で渡す。`printf | grep -q` の形にすると、grep がマッチして即終了した瞬間に上流が SIGPIPE で死に、pipefail のせいで「マッチしなかった」と判定される。
PR_MERGE_NUM_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+"
PR_MERGE_SEGMENT_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+merge[^;&|)]*"
PR_MERGE_BAD_METHOD_RE='(^|[[:space:]])(--squash|--rebase|-s|-r)([[:space:]=]|$)'

if grep -qE "$PR_MERGE_RE" <<<"$stripped"; then
  if ! grep -qE "$PR_MERGE_NUM_RE" <<<"$stripped"; then
    respond deny "🚫 gh pr merge は PR 番号を明示してください（例: gh pr merge 123 --merge）。番号を省略するとカレントブランチの open PR が暗黙に対象になり、--delete-branch 併用時は実行後に対象を特定し直せなくなります。"
  fi
  pr_merge_segment="$(grep -oE "$PR_MERGE_SEGMENT_RE" <<<"$stripped" | head -1)"
  if grep -qE "$PR_MERGE_BAD_METHOD_RE" <<<"$pr_merge_segment"; then
    respond deny "🚫 squash / rebase でのマージは禁止です。マージコミット方式だけを使ってください。--squash / --rebase（短縮形の -s / -r も含む）を外し、--merge を付けて実行し直してください（例: gh pr merge 123 --merge --delete-branch）。"
  fi
  if ! is_exempt_repo "$HOOK_CWD"; then
    respond ask "🔀 マージは事前確認が必要な操作です。マージまで進めてよいかユーザーに確認してください。作業を止めるよう言われた直後でないかも確認してください。"
  fi
elif grep -qE "$MERGE_RE" <<<"$stripped"; then
  if ! is_exempt_repo "$HOOK_CWD"; then
    respond ask "🔀 マージは事前確認が必要な操作です。マージまで進めてよいかユーザーに確認してください。作業を止めるよう言われた直後でないかも確認してください。"
  fi
fi

if grep -qE "$PULL_RE" <<<"$stripped"; then
  [[ -z "$HOOK_CWD" ]] && exit 0
  DIRTY="$(git -C "$HOOK_CWD" status --porcelain 2>/dev/null || true)"
  if [[ -n "$DIRTY" ]]; then
    respond deny "🚫 未コミットの変更があるまま git pull しようとしています。先に \`git stash push -u\` で退避させてから pull し、pull 後に \`git stash pop\` で戻してください。この順を飛ばすとコミット前の変更を失います。"
  fi
fi

exit 0
