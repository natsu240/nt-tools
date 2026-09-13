#!/usr/bin/env bash

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/gate-branch-op-approval.sh"
[[ -f "$HOOK" ]] || { echo "gate-branch-op-approval.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

NON_EXEMPT_REPO="$TMP_ROOT/other-repo"
mkdir -p "$NON_EXEMPT_REPO"
git -C "$NON_EXEMPT_REPO" init -q
git -C "$NON_EXEMPT_REPO" commit -q --allow-empty -m init

DIRTY_REPO="$TMP_ROOT/dirty-repo"
mkdir -p "$DIRTY_REPO"
git -C "$DIRTY_REPO" init -q
git -C "$DIRTY_REPO" commit -q --allow-empty -m init
printf 'x' >"$DIRTY_REPO/untracked.txt"

CLEAN_REPO="$TMP_ROOT/clean-repo"
mkdir -p "$CLEAN_REPO"
git -C "$CLEAN_REPO" init -q
git -C "$CLEAN_REPO" commit -q --allow-empty -m init

EXEMPT_REPO="$TMP_ROOT/exempt-repo"
mkdir -p "$EXEMPT_REPO/project_notes"
git -C "$EXEMPT_REPO" init -q
git -C "$EXEMPT_REPO" commit -q --allow-empty -m init
printf '# メモ\n\nclaude-merge-approval: skip\n' >"$EXEMPT_REPO/project_notes/automation.md"
EXEMPT_WORKTREE="$TMP_ROOT/exempt-repo-issue-1"
git -C "$EXEMPT_REPO" worktree add -q -b issue-1 "$EXEMPT_WORKTREE" >/dev/null 2>&1

NOTES_WITHOUT_MARKER_REPO="$TMP_ROOT/notes-without-marker"
mkdir -p "$NOTES_WITHOUT_MARKER_REPO/project_notes"
git -C "$NOTES_WITHOUT_MARKER_REPO" init -q
git -C "$NOTES_WITHOUT_MARKER_REPO" commit -q --allow-empty -m init
printf '# メモ\n\nマージ前の確認は claude-merge-approval: skip を書けば省ける。ここでは省いていない。\n' \
  >"$NOTES_WITHOUT_MARKER_REPO/project_notes/automation.md"

failures=0
total=0

classify() {
  if [[ -z "$1" ]]; then
    echo pass
  elif grep -q '"permissionDecision": "deny"' <<<"$1"; then
    echo deny
  elif grep -q '"permissionDecision": "ask"' <<<"$1"; then
    echo ask
  else
    echo other
  fi
}

run_case() {
  local expected=$1 label=$2 cmd=$3 cwd=${4:-}
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' | bash "$HOOK" 2>&1)"
  actual="$(classify "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- gh pr merge は PR 番号必須 → 番号無しは deny（exempt かどうかより先に判定） ---
run_case deny "PR 番号無しの gh pr merge" 'gh pr merge --merge --delete-branch' "$NON_EXEMPT_REPO"

# --- PR 番号ありの gh pr merge → exempt でなければ ask ---
run_case ask "PR 番号ありの gh pr merge（非 exempt）" 'gh pr merge 123 --merge' "$NON_EXEMPT_REPO"

# --- squash / rebase でのマージは deny（マーカー行の有無によらない） ---
run_case deny "gh pr merge --squash" 'gh pr merge 123 --squash' "$NON_EXEMPT_REPO"
run_case deny "gh pr merge --rebase" 'gh pr merge 123 --rebase' "$NON_EXEMPT_REPO"
run_case deny "gh pr merge -s（短縮形）" 'gh pr merge 123 -s -d' "$NON_EXEMPT_REPO"
run_case deny "gh pr merge -r（短縮形）" 'gh pr merge 123 -r' "$NON_EXEMPT_REPO"
run_case deny "gh pr merge --squash（マーカー行あり）" 'gh pr merge 123 --squash --delete-branch' "$EXEMPT_REPO"

# --- 止めてはいけない例 ---
run_case ask "--merge に --delete-branch を併用" 'gh pr merge 123 --merge --delete-branch' "$NON_EXEMPT_REPO"
run_case pass "コミットメッセージに --squash と書く" "git commit -m 'gh pr merge --squash をやめた'" "$NON_EXEMPT_REPO"
run_case pass "別コマンドに付いた --squash" 'git log --oneline; ls -s' "$NON_EXEMPT_REPO"

# --- git merge → exempt でなければ ask ---
run_case ask "git merge（非 exempt）" 'git merge feature-branch' "$NON_EXEMPT_REPO"

# --- project_notes/automation.md にマーカー行がある → 確認を挟まず素通し ---
run_case pass "PR 番号ありの gh pr merge（マーカー行あり）" 'gh pr merge 123 --merge' "$EXEMPT_REPO"
run_case pass "git merge（マーカー行あり）" 'git merge feature-branch' "$EXEMPT_REPO"

# --- マーカー行を持つリポジトリの worktree → 本体の project_notes/automation.md を見るので素通し ---
run_case pass "PR 番号ありの gh pr merge（マーカー行ありリポジトリの worktree）" 'gh pr merge 123 --merge' "$EXEMPT_WORKTREE"
run_case pass "git merge（マーカー行ありリポジトリの worktree）" 'git merge feature-branch' "$EXEMPT_WORKTREE"

# --- project_notes/automation.md はあるがマーカー行が無い（散文中に文字列が出るだけ）→ 確認する側に倒す ---
run_case ask "散文の中にマーカー文字列が出るだけ" 'git merge feature-branch' "$NOTES_WITHOUT_MARKER_REPO"

# --- 未コミットの変更があるまま git pull → deny ---
run_case deny "未コミットの変更がある git pull" 'git pull' "$DIRTY_REPO"

# --- クリーンな作業ツリーでの git pull → 何もしない ---
run_case pass "クリーンな作業ツリーの git pull" 'git pull' "$CLEAN_REPO"

# --- ブランチ作成・worktree は対象外 → 素通し ---
run_case pass "ブランチ作成は対象外" 'git branch feature-x' "$NON_EXEMPT_REPO"
run_case pass "git worktree add は対象外" 'git worktree add ../wt -b feature-x' "$NON_EXEMPT_REPO"

# --- クォート内の文字列として現れるだけ → 素通し ---
run_case pass "コミットメッセージに git merge と書く" "git commit -m 'git merge の挙動を直した'" "$NON_EXEMPT_REPO"

if [[ "$failures" -gt 0 ]]; then
  printf '\nbranch-op-approval-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'branch-op-approval-gate: %d 件すべて期待どおり\n' "$total"
