#!/usr/bin/env bash

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-worktree-for-edit.sh"
[[ -f "$HOOK" ]] || { echo "deny-worktree-for-edit.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

MAIN_TREE="$TMP_ROOT/nt-tools"
mkdir -p "$MAIN_TREE/plugins"
git -C "$MAIN_TREE" init -q -b main
git -C "$MAIN_TREE" commit -q --allow-empty -m init

WORKTREE="$TMP_ROOT/nt-tools-issue-1"
git -C "$MAIN_TREE" worktree add -q -b issue-1 "$WORKTREE" >/dev/null 2>&1

DOCS_WORKTREE="$TMP_ROOT/nt-tools-docs"
git -C "$MAIN_TREE" worktree add -q --detach "$DOCS_WORKTREE" >/dev/null 2>&1

LARAVEL_MAIN="$TMP_ROOT/sample-laravel-app"
mkdir -p "$LARAVEL_MAIN/html"
git -C "$LARAVEL_MAIN" init -q -b main
git -C "$LARAVEL_MAIN" commit -q --allow-empty -m init

LARAVEL_WORKTREE="$TMP_ROOT/sample-laravel-app-issue-1"
git -C "$LARAVEL_MAIN" worktree add -q -b issue-1 "$LARAVEL_WORKTREE" >/dev/null 2>&1

OTHER_REPO="$TMP_ROOT/sample-api-app"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q -b main
git -C "$OTHER_REPO" commit -q --allow-empty -m init

OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$OUTSIDE"

printf '**/plans/\n' > "$MAIN_TREE/.git/info/exclude"
mkdir -p "$MAIN_TREE/plans/進行中/other"

failures=0
total=0

run_case() {
  local expected=$1 label=$2 json=$3
  local out actual
  total=$((total + 1))
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

edit_json() {
  jq -n --arg p "$1" --arg cwd "$2" '{tool_name: "Edit", tool_input: {file_path: $p}, cwd: $cwd}'
}

write_json() {
  jq -n --arg p "$1" --arg cwd "$2" '{tool_name: "Write", tool_input: {file_path: $p}, cwd: $cwd}'
}

bash_json() {
  jq -n --arg c "$1" --arg cwd "$2" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd}'
}

# --- 本体の作業ツリーでの変更 → 拒否 ---
run_case deny "本体での Edit" "$(edit_json "$MAIN_TREE/plugins/a.sh" "$MAIN_TREE")"
run_case deny "本体のサブディレクトリへの Write" "$(write_json "$MAIN_TREE/plugins/nested/a.sh" "$MAIN_TREE")"
run_case deny "本体での git commit" "$(bash_json "git commit -m x" "$MAIN_TREE")"
run_case deny "本体での git add" "$(bash_json "git add plugins/a.sh" "$MAIN_TREE")"
run_case deny "本体での git push" "$(bash_json "git push origin main" "$MAIN_TREE")"

# --- worktree 側での変更 → 素通し ---
run_case pass "worktree での Edit" "$(edit_json "$WORKTREE/plugins/a.sh" "$WORKTREE")"
run_case pass "worktree での git commit" "$(bash_json "git commit -m x" "$WORKTREE")"
run_case pass "worktree での git push" "$(bash_json "git push origin issue-1" "$WORKTREE")"

# --- 本体で行う作業（ブランチ移動・取り込み・マージ・worktree 操作・掃除）→ 素通し ---
run_case pass "本体での git worktree add" "$(bash_json "git worktree add ../nt-tools-issue-1 issue-1" "$MAIN_TREE")"
run_case pass "本体での git fetch" "$(bash_json "git fetch origin" "$MAIN_TREE")"
run_case pass "本体での git pull" "$(bash_json "git pull origin main" "$MAIN_TREE")"
run_case pass "本体での git switch" "$(bash_json "git switch main" "$MAIN_TREE")"
run_case pass "本体での gh pr merge" "$(bash_json "gh pr merge 123 --merge" "$MAIN_TREE")"
run_case pass "本体での git branch -d" "$(bash_json "git branch -d issue-1" "$MAIN_TREE")"
run_case pass "本体での読み取り専用 git status" "$(bash_json "git status" "$MAIN_TREE")"

# --- コマンドの中で移動先を指定している場合、移動先で判定する ---
run_case pass "本体から worktree へ cd してからの git add" "$(bash_json "cd $WORKTREE && git add plugins/a.sh" "$MAIN_TREE")"
run_case pass "本体から worktree へ相対パスで cd してからの git add" "$(bash_json "cd ../nt-tools-issue-1 && git add plugins/a.sh" "$MAIN_TREE")"
run_case pass "worktree を git -C で指定した git add" "$(bash_json "git -C $WORKTREE add plugins/a.sh" "$MAIN_TREE")"
run_case deny "worktree から本体へ cd してからの git add" "$(bash_json "cd $MAIN_TREE && git add plugins/a.sh" "$WORKTREE")"
run_case deny "本体を git -C で指定した git add" "$(bash_json "git -C $MAIN_TREE add plugins/a.sh" "$WORKTREE")"
run_case deny "実在しないディレクトリへの cd（.cwd で判定する）" "$(bash_json "cd $TMP_ROOT/nowhere && git add plugins/a.sh" "$MAIN_TREE")"
run_case pass "cd を文字列として書くだけ" "$(bash_json "gh pr comment 1 --body 'cd $WORKTREE してから git add しろ'" "$WORKTREE")"

# --- --detach で切り出したワークツリーを git -C で指定する（README / CLAUDE.md の main 直 push の経路） ---
run_case pass "本体から --detach のワークツリーを git -C で指定した git add" "$(bash_json "git -C $DOCS_WORKTREE add CLAUDE.md" "$MAIN_TREE")"
run_case pass "パスをクォートで囲んだ git -C" "$(bash_json "git -C \"$DOCS_WORKTREE\" add CLAUDE.md" "$MAIN_TREE")"
run_case pass "--detach のワークツリーからの git push" "$(bash_json "git -C $DOCS_WORKTREE push origin HEAD:main" "$MAIN_TREE")"
run_case deny "本体を git -C で指定すればクォートしても止める" "$(bash_json "git -C \"$MAIN_TREE\" add CLAUDE.md" "$DOCS_WORKTREE")"
run_case deny "実在しないパスを git -C で指定したら .cwd で判定する" "$(bash_json "git -C $TMP_ROOT/nowhere add CLAUDE.md" "$MAIN_TREE")"

# --- Docker 前提のリポジトリは強制対象外 → 本体でも素通し ---
run_case pass "Docker 前提リポジトリの本体での Edit" "$(edit_json "$LARAVEL_MAIN/html/a.php" "$LARAVEL_MAIN")"
run_case pass "Docker 前提リポジトリの本体での git commit" "$(bash_json "git commit -m x" "$LARAVEL_MAIN")"
run_case pass "Docker 前提リポジトリの worktree での Edit" "$(edit_json "$LARAVEL_WORKTREE/html/a.php" "$LARAVEL_WORKTREE")"

# --- 強制対象に入っていないリポジトリ → 素通し ---
run_case pass "対象外リポジトリの本体での Edit" "$(edit_json "$OTHER_REPO/a.ts" "$OTHER_REPO")"
run_case pass "対象外リポジトリの本体での git commit" "$(bash_json "git commit -m x" "$OTHER_REPO")"

# --- git 管理外 → 素通し ---
run_case pass "git 管理外への Write" "$(write_json "$OUTSIDE/settings.json" "$OUTSIDE")"
run_case pass "本体の plans/ への Write" "$(write_json "$MAIN_TREE/plans/進行中/other/計画.md" "$MAIN_TREE")"

# --- クォート内の文字列として現れるだけ → 素通し ---
run_case pass "コミットメッセージに git add と書く" "$(bash_json "gh pr comment 1 --body 'git add の手順を直した'" "$MAIN_TREE")"

if [[ "$failures" -gt 0 ]]; then
  printf '\nworktree-required-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'worktree-required-gate: %d 件すべて期待どおり\n' "$total"
