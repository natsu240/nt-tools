#!/usr/bin/env bash

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-branch-create-in-main.sh"
[[ -f "$HOOK" ]] || { echo "deny-branch-create-in-main.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

MAIN_TREE="$TMP_ROOT/nt-tools"
mkdir -p "$MAIN_TREE"
git -C "$MAIN_TREE" init -q -b main
git -C "$MAIN_TREE" commit -q --allow-empty -m init

WORKTREE="$TMP_ROOT/nt-tools-issue-1"
git -C "$MAIN_TREE" worktree add -q -b issue-1 "$WORKTREE" >/dev/null 2>&1

# Docker 前提のリポジトリは強制対象外であることを確かめる。
LARAVEL_MAIN="$TMP_ROOT/sample-laravel-app"
mkdir -p "$LARAVEL_MAIN"
git -C "$LARAVEL_MAIN" init -q -b main
git -C "$LARAVEL_MAIN" commit -q --allow-empty -m init

# 強制対象に入っていないリポジトリ。
OTHER_REPO="$TMP_ROOT/sample-api-app"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q -b main
git -C "$OTHER_REPO" commit -q --allow-empty -m init

OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$OUTSIDE"

failures=0
total=0

run_case() {
  local expected=$1 label=$2 cmd=$3 cwd=$4
  local out actual json
  total=$((total + 1))
  json="$(jq -n --arg c "$cmd" --arg cwd "$cwd" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd}')"
  out="$(printf '%s' "$json" | bash "$HOOK" 2>&1)"
  if [[ -z "$out" ]]; then
    actual="pass"
  elif grep -q '"permissionDecision": "deny"' <<<"$out"; then
    actual="deny"
  else
    actual="other"
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    出力: %s\n' "$out"
  fi
}

# --- 本体でのブランチ作成 → 拒否 ---
run_case deny "本体での git switch -c" "git switch -c issue-2" "$MAIN_TREE"
run_case deny "本体での git switch --create" "git switch --create issue-2" "$MAIN_TREE"
run_case deny "本体での git checkout -b" "git checkout -b issue-2" "$MAIN_TREE"
run_case deny "本体での git checkout --track -b" "git checkout --track -b issue-2 origin/issue-2" "$MAIN_TREE"
run_case deny "本体での gh issue develop --checkout" "gh issue develop 634 --checkout -n issue-634" "$MAIN_TREE"
run_case deny "本体での gh issue develop -c" "gh issue develop 634 -c" "$MAIN_TREE"
run_case deny "本体での gh issue develop（フラグが番号より先）" "gh issue develop -c 634" "$MAIN_TREE"
run_case deny "本体を git -C で指定したブランチ作成" "git -C $MAIN_TREE switch -c issue-2" "$WORKTREE"
run_case deny "worktree から本体へ cd してからのブランチ作成" "cd $MAIN_TREE && git switch -c issue-2" "$WORKTREE"

# --- ワークツリーの中でのブランチ作成 → 素通し ---
run_case pass "worktree での git switch -c" "git switch -c issue-1-fix" "$WORKTREE"
run_case pass "worktree での git checkout -b" "git checkout -b issue-1-fix" "$WORKTREE"
run_case pass "worktree での gh issue develop --checkout" "gh issue develop 634 --checkout" "$WORKTREE"
run_case pass "本体から worktree へ cd してからのブランチ作成" "cd $WORKTREE && git switch -c issue-1-fix" "$MAIN_TREE"

# --- ブランチを作らない操作 → 素通し ---
run_case pass "本体での git switch（既存ブランチへ移動）" "git switch main" "$MAIN_TREE"
run_case pass "本体での git checkout（既存ブランチへ移動）" "git checkout main" "$MAIN_TREE"
run_case pass "本体での git checkout（ファイルの復元）" "git checkout -- plugins/a.sh" "$MAIN_TREE"
run_case pass "本体での git worktree add --detach" "git worktree add --detach ../nt-tools-docs" "$MAIN_TREE"
run_case pass "本体での gh issue develop --list" "gh issue develop --list 634" "$MAIN_TREE"
run_case pass "本体での gh issue develop（--checkout なし）" "gh issue develop 634 -n issue-634" "$MAIN_TREE"
run_case pass "本体での git fetch" "git fetch origin" "$MAIN_TREE"
run_case pass "本体での git branch 一覧" "git branch -vv" "$MAIN_TREE"
run_case pass "-n の値に c を含むだけの gh issue develop" "gh issue develop 634 -n cache-fix" "$MAIN_TREE"

# --- 対象外のリポジトリ・git 管理外 → 素通し ---
run_case pass "強制対象外リポジトリの本体での git switch -c" "git switch -c feature-x" "$OTHER_REPO"
run_case pass "Docker 前提リポジトリの本体での git switch -c" "git switch -c issue-2" "$LARAVEL_MAIN"
run_case pass "git 管理外での git switch -c" "git switch -c feature-x" "$OUTSIDE"

# --- クォート内の文字列として現れるだけ → 素通し ---
run_case pass "コミットメッセージに git switch -c と書く" "gh pr comment 1 --body 'git switch -c の手順を直した'" "$MAIN_TREE"
run_case pass "本文に gh issue develop --checkout と書く" "gh pr comment 1 --body 'gh issue develop --checkout は使うな'" "$MAIN_TREE"

if [[ "$failures" -gt 0 ]]; then
  printf '\nbranch-create-in-main-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'branch-create-in-main-gate: %d 件すべて期待どおり\n' "$total"
