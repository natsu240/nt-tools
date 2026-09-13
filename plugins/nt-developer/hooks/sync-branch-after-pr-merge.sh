#!/usr/bin/env bash
# gh pr merge の Bash PostToolUse hook（ツールが成功したときだけ発火する）。マージ後のローカルの後始末をする。
#
# **base を進めるのに git pull を使うな。**FETCH_HEAD 経由なので、fetch が並行すると「Cannot fast-forward to multiple branches.」で落ちる。
# `git fetch` した後に `origin/<base>` を ref で明示して `git merge` しろ。
#
# gh は `--delete-branch` 付きでも pull の失敗を警告で流すので、base が遅れたまま残る。
# deleteBranchOnMerge が有効でも GitHub が消すのはリモートだけで、ローカルは自分で消す。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"
# shellcheck source=lib-orca-worktree.sh
source "${BASH_SOURCE[0]%/*}/lib-orca-worktree.sh"
stripped="$(strip_quoted "$command")"

CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z0-9_.-]*/)*'
PR_MERGE_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+"

grep -qE "$PR_MERGE_RE" <<<"$stripped" || exit 0

pr_number="$(grep -oE "$PR_MERGE_RE" <<<"$stripped" | grep -oE '[0-9]+$' | head -1 || true)"
[[ -z "$pr_number" ]] && exit 0

delete_branch_flag=false
if grep -qE '(^|[[:space:]])(--delete-branch|-d)([[:space:]]|$)' <<<"$stripped"; then
  delete_branch_flag=true
fi

HOOK_CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
[[ -z "$HOOK_CWD" ]] && exit 0

repo_root="$(git -C "$HOOK_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$repo_root" ]] && exit 0

main_sync_note=""
worktree_note=""

respond_message() {
  local msg="$1"
  local note
  for note in "$main_sync_note" "$worktree_note"; do
    [[ -n "$note" ]] && msg="${msg}
${note}"
  done
  jq -n --arg msg "$msg" '{systemMessage: $msg}'
  exit 0
}

finish() {
  [[ -n "$main_sync_note" || -n "$worktree_note" ]] && respond_message "🔀 PR #${pr_number} をマージしました"
  exit 0
}

base_branch="$(gh pr view "$pr_number" --json baseRefName -q .baseRefName 2>/dev/null || true)"
[[ -z "$base_branch" ]] && exit 0

main_worktree="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10); exit}' || true)"

if [[ -n "$main_worktree" && "$main_worktree" != "$repo_root" ]]; then
  main_current="$(git -C "$main_worktree" branch --show-current 2>/dev/null || true)"
  if [[ "$main_current" == "$base_branch" ]]; then
    git -C "$main_worktree" fetch origin "$base_branch" >/dev/null 2>&1 || true
    if git -C "$main_worktree" merge --ff-only "origin/${base_branch}" >/dev/null 2>&1; then
      main_sync_note="🏠 本体のチェックアウト（${main_worktree}）の ${base_branch} も origin/${base_branch} に追いつかせました"
    else
      main_sync_note="⚠️ 本体のチェックアウト（${main_worktree}）の ${base_branch} を追いつかせられませんでした。\`git -C ${main_worktree} merge --ff-only origin/${base_branch}\` を手動で実行してください。"
    fi
  elif git -C "$main_worktree" fetch origin "${base_branch}:${base_branch}" >/dev/null 2>&1; then
    main_sync_note="🏠 本体のチェックアウト（${main_worktree}）は ${main_current:-detached HEAD} に居るため、${base_branch} の ref だけ origin に追いつかせました"
  else
    main_sync_note="⚠️ 本体のチェックアウト（${main_worktree}）の ${base_branch} を更新できませんでした。手動で確認してください。"
  fi
fi

head_branch="$(gh pr view "$pr_number" --json headRefName -q .headRefName 2>/dev/null || true)"
auto_delete="$(gh repo view --json deleteBranchOnMerge -q .deleteBranchOnMerge 2>/dev/null || echo false)"

if [[ -n "$main_worktree" && "$main_worktree" == "$repo_root" && -n "$head_branch" ]]; then
  head_worktree="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$head_branch" '/^worktree /{p=substr($0, 10)} /^branch /{if ($2 == b) print p}' || true)"

  if [[ -n "$head_worktree" && "$head_worktree" != "$main_worktree" ]] && remote_branch_gone "$repo_root" "$head_branch"; then
    if remove_worktree "$head_worktree" "$main_worktree"; then
      worktree_note="🧹 ${head_branch} の作業ツリー（${head_worktree}）を畳みました"
    elif worktree_has_local_changes "$head_worktree"; then
      worktree_note="⚠️ ${head_branch} の作業ツリー（${head_worktree}）に未コミットの変更が残っているため畳みませんでした。手動で確認してください。"
    else
      worktree_note="⚠️ ${head_branch} の作業ツリー（${head_worktree}）を畳めませんでした。手動で確認してください。"
    fi
  fi
fi

current_branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"

# gh が base へ切り替えるのは今のブランチが PR の head と一致するときだけで、base に居ないなら pull もされていない。
if [[ "$delete_branch_flag" == "true" && "$current_branch" == "$base_branch" ]]; then
  git -C "$repo_root" fetch origin "$base_branch" >/dev/null 2>&1 || true
  behind="$(git -C "$repo_root" rev-list --count "HEAD..origin/${base_branch}" 2>/dev/null || echo 0)"

  if [[ "$behind" != "0" ]]; then
    if git -C "$repo_root" merge --ff-only "origin/${base_branch}" >/dev/null 2>&1; then
      respond_message "🔀 PR #${pr_number} のマージ後、gh の pull が効かずローカルの ${base_branch} が ${behind} コミット遅れていたため、origin/${base_branch} に追いつかせました"
    else
      respond_message "⚠️ PR #${pr_number} のマージ後、ローカルの ${base_branch} が origin より ${behind} コミット遅れていますが追いつかせられませんでした。\`git merge --ff-only origin/${base_branch}\` を手動で実行してください。"
    fi
  fi
fi

if [[ "$auto_delete" == "true" ]]; then
  # 現在のブランチが head と一致しないなら何もしない（別作業に移っている等）。
  if [[ -z "$head_branch" || "$current_branch" != "$head_branch" ]]; then
    finish
  fi

  if ! git -C "$repo_root" switch "$base_branch" >/dev/null 2>&1; then
    respond_message "⚠️ PR #${pr_number} のマージ後、${base_branch} への switch に失敗しました。手動で確認してください。"
  fi

  git -C "$repo_root" fetch origin "$base_branch" >/dev/null 2>&1 || true
  git -C "$repo_root" merge --ff-only "origin/${base_branch}" >/dev/null 2>&1 || true

  if git -C "$repo_root" branch -d "$head_branch" >/dev/null 2>&1; then
    respond_message "🔀 PR #${pr_number} のマージに伴い、リモート自動削除設定が有効なため ${base_branch} に切り替えて最新化し、ローカルブランチ ${head_branch} を削除しました"
  else
    respond_message "⚠️ PR #${pr_number} のマージに伴い ${base_branch} に切り替えましたが、ローカルブランチ ${head_branch} の削除に失敗しました。手動で確認してください。"
  fi
else
  if git -C "$repo_root" fetch origin "$base_branch" >/dev/null 2>&1 \
    && git -C "$repo_root" merge "origin/${base_branch}" >/dev/null 2>&1; then
    respond_message "🔀 PR #${pr_number} のマージに伴い、現在のブランチのまま origin/${base_branch} を取り込みました"
  else
    respond_message "⚠️ PR #${pr_number} のマージ後、origin/${base_branch} の取り込みに失敗しました。手動で確認してください。"
  fi
fi

exit 0
