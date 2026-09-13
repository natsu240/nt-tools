#!/usr/bin/env bash
# deny-write-to-current-project.sh の検査。
# git は hook 経由の実行時に GIT_DIR を渡すことがあり、残っていると一時リポジトリ向けの git 操作がこのリポジトリを対象にしてしまう。
# **検査用のリポジトリを /tmp や $TMPDIR 配下（mktemp -d の既定）へ移すな。** hook がそこを対象外にしているため、止めるべき書き込みが素通しになる。

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-write-to-current-project.sh"
[[ -f "$HOOK" ]] || { echo "deny-write-to-current-project.sh が見つかりません: $HOOK"; exit 1; }

mkdir -p "$HOME/.cache"
TMP_ROOT="$(mktemp -d "$HOME/.cache/nt-write-current-project.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

init_repo() {
  local dir="$1" origin="$2"
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" -c user.email=t@example.com -c user.name=t commit --quiet --allow-empty -m init
}

REPO_A="$TMP_ROOT/nt-tools"
REPO_B="$TMP_ROOT/sample-app"
init_repo "$REPO_A" "git@github.com:natsu240/nt-tools.git"
init_repo "$REPO_B" "git@github.com:natsu240/sample-app.git"

WORKTREE_A="$TMP_ROOT/nt-tools-issue-601"
git -C "$REPO_A" worktree add --quiet -b issue-601 "$WORKTREE_A" >/dev/null 2>&1

# hook が一時領域として扱う TMPDIR を、実際の TMPDIR から切り離して固定する。
FAKE_TMPDIR="$TMP_ROOT/tmpdir"
mkdir -p "$FAKE_TMPDIR"

failures=0
total=0

judge() {
  local out=$1
  if [[ -z "$out" ]]; then
    printf 'pass'
  elif grep -qE '"permissionDecision":[[:space:]]*"deny"' <<<"$out"; then
    printf 'deny'
  else
    printf 'other'
  fi
}

run_write() {
  local expected=$1 label=$2 file=$3
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg f "$file" --arg cwd "$REPO_A" '{tool_name: "Write", tool_input: {file_path: $f}, cwd: $cwd}' | TMPDIR="$FAKE_TMPDIR" bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    パス: %s\n' "$file"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

run_bash() {
  local expected=$1 label=$2 cmd=$3
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg c "$cmd" --arg cwd "$REPO_A" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd}' | TMPDIR="$FAKE_TMPDIR" bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 別プロジェクトへの書き込み → 止める ---
run_write deny "別リポジトリの既存ディレクトリ配下" "$REPO_B/README.md"
run_write deny "別リポジトリの未作成ディレクトリ配下" "$REPO_B/plugins/new/SKILL.md"
run_write deny "別リポジトリの .claude 配下のコミット対象" "$REPO_B/.claude/settings.json"

# --- 止めてはいけない例 ---
run_write pass "起動時プロジェクト内" "$REPO_A/README.md"
run_write pass "同じリポジトリの worktree 内" "$WORKTREE_A/README.md"
run_write pass "スクラッチパッド" "/private/tmp/claude-501/proj/session/scratchpad/x.md"
run_write pass "~/.claude 配下" "$HOME/.claude/settings.json"
run_write pass "git 管理外のパス" "$TMP_ROOT/loose/note.md"
run_write pass "TMPDIR 配下" "$FAKE_TMPDIR/note.md"
run_write pass "別リポジトリの project_notes/" "$REPO_B/project_notes/environment.md"

# --- 別リポジトリを名指しした gh の副作用操作 → 止める ---
run_bash deny "別リポジトリへの Issue 起票" 'gh issue create --repo natsu240/sample-app --title x --body y'
run_bash deny "-R 指定での PR 作成" 'gh pr create -R natsu240/sample-app --title x --body y'
run_bash deny "owner 省略の別リポジトリ指定" 'gh issue comment 1 --repo sample-app --body x'

# --- 止めてはいけない例 ---
run_bash pass "--repo 無しの Issue 起票" 'gh issue create --title x --body y'
run_bash pass "同一リポジトリを名指しした Issue 起票" 'gh issue create --repo natsu240/nt-tools --title x --body y'
run_bash pass "別リポジトリでも読み取りは通す" 'gh issue view 221 --repo natsu240/sample-app --json body'
run_bash pass "別リポジトリの一覧取得" 'gh pr list --repo natsu240/sample-app --state open'
run_bash pass "PR 本文に別リポジトリ名を書くだけ" "gh pr create --title x --body 'gh issue create --repo natsu240/sample-app は禁止'"

if [[ "$failures" -gt 0 ]]; then
  printf '\nwrite-current-project-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'write-current-project-gate: %d 件すべて期待どおり\n' "$total"
