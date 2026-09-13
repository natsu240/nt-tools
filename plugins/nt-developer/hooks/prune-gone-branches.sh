#!/bin/bash
set -euo pipefail

FETCH_TIMEOUT=15

# shellcheck source=lib-orca-worktree.sh
source "${BASH_SOURCE[0]%/*}/lib-orca-worktree.sh"

# hook 自身は fetch しないため、直前のコマンドが prune を伴わないと gone が立たない。判定材料を先に最新化する。
fetch_prune() {
  local remotes
  remotes=$(git remote 2>/dev/null) || return 0
  grep -qx origin <<<"$remotes" || return 0

  local bin
  bin=$(orca_timeout_bin)

  if [ -n "$bin" ]; then
    "$bin" "$FETCH_TIMEOUT" git fetch --prune --quiet origin >/dev/null 2>&1 || true
  else
    git fetch --prune --quiet origin >/dev/null 2>&1 || true
  fi
}

MAIN_WORKTREE=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)") || true

fetch_prune

gone_branches=$(git branch -vv 2>/dev/null | grep ': gone]' | sed 's/^[*+ ] //' | awk '{print $1}') || true

git worktree prune >/dev/null 2>&1 || true

if [ -z "$gone_branches" ]; then
  exit 0
fi

removed_worktrees=""
kept_worktrees=""
deleted=""
skipped=""
while IFS= read -r branch; do
  [ -z "$branch" ] && continue

  worktree_path=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{p=$2} /^branch /{if ($2 == b) print p}')
  if [ -n "$worktree_path" ]; then
    if remove_worktree "$worktree_path" "$MAIN_WORKTREE"; then
      removed_worktrees="$removed_worktrees $worktree_path"
    elif worktree_has_local_changes "$worktree_path"; then
      kept_worktrees="$kept_worktrees $worktree_path"
      continue
    fi
  fi

  # orca worktree rm はワークツリーと一緒にブランチも削除する。
  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    deleted="$deleted $branch"
    continue
  fi

  if git branch -d "$branch" >/dev/null 2>&1; then
    deleted="$deleted $branch"
    continue
  fi

  skipped="$skipped $branch"
done <<< "$gone_branches"

message=""
if [ -n "$removed_worktrees" ]; then
  message="リモートで削除済みのブランチの作業ツリーを畳みました:${removed_worktrees}"
fi
if [ -n "$kept_worktrees" ]; then
  [ -n "$message" ] && message="${message}\\n"
  message="${message}未コミットの変更が残っているため畳まなかった作業ツリー:${kept_worktrees}"
fi
if [ -n "$deleted" ]; then
  [ -n "$message" ] && message="${message}\\n"
  message="${message}リモートで削除済みのローカルブランチを削除しました:${deleted}"
fi
if [ -n "$skipped" ]; then
  [ -n "$message" ] && message="${message}\\n"
  message="${message}リモートでは削除済みですが git branch -d で削除できなかったブランチ（手動確認してください）:${skipped}"
fi

if [ -n "$message" ]; then
  printf '{"systemMessage": "%s"}\n' "$message"
fi

exit 0
