#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-git-worktree-add.sh"
[[ -f "$HOOK" ]] || { echo "deny-git-worktree-add.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

run_case() {
  local expected=$1 label=$2 command=$3
  local json out actual
  total=$((total + 1))
  json="$(jq -n --arg c "$command" '{tool_name: "Bash", tool_input: {command: $c}}')"
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

# --- 止める例 ---
run_case deny "ブランチ名を渡す worktree add" 'git worktree add ../nt-tools-issue-1 issue-1'
run_case deny "-b で新規ブランチを切る worktree add" 'git worktree add ../wt -b issue-1'
run_case deny "git -C 付きの worktree add" 'git -C /tmp/repo worktree add ../wt -b issue-1'
run_case deny "&& の後ろの worktree add" 'git fetch origin && git worktree add ../wt issue-1'
run_case deny "絶対パスの git での worktree add" '/usr/bin/git worktree add ../wt issue-1'

# --- 止めてはいけない例 ---
run_case pass "--detach（README / CLAUDE.md だけの main 直 push が使う）" \
  'git worktree add --detach ../nt-tools-docs'
run_case pass "git -C 付きの --detach" 'git -C /tmp/repo worktree add --detach /tmp/wt'
run_case pass "worktree list" 'git worktree list --porcelain'
run_case pass "worktree remove" 'git worktree remove ../wt'
run_case pass "worktree prune" 'git worktree prune'
run_case pass "orca worktree create" \
  'orca worktree create --repo path:/tmp/repo --name issue-1 --base-branch main --agent claude --prompt "やれ" --json'
run_case pass "クォートの中に worktree add と書くだけ" \
  "gh pr comment 1 --body 'git worktree add はもう使わない'"
run_case pass "worktree add を grep するだけ" "grep -rn 'git worktree add' ./docs"

if [[ "$failures" -gt 0 ]]; then
  printf '\ngit-worktree-add-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'git-worktree-add-gate: %d 件すべて期待どおり\n' "$total"
