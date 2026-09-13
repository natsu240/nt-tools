#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-orca-worktree-without-agent.sh"
[[ -f "$HOOK" ]] || { echo "deny-orca-worktree-without-agent.sh が見つかりません: $HOOK"; exit 1; }

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
run_case deny "--agent も --prompt も無い" \
  'orca worktree create --repo path:/tmp/repo --name issue-1 --base-branch main --issue 1 --json'
run_case deny "--agent だけ" \
  'orca worktree create --repo path:/tmp/repo --name issue-1 --agent claude --json'
run_case deny "--prompt だけ" \
  'orca worktree create --repo path:/tmp/repo --name issue-1 --prompt "やれ" --json'
run_case deny "&& の後ろ" \
  'git fetch origin && orca worktree create --repo path:/tmp/repo --name issue-1 --json'
run_case deny "コマンド置換の中の作成" \
  'wt=$(orca worktree create --repo path:/tmp/repo --name issue-1 --json)'

# --- 止めてはいけない例 ---
run_case pass "--agent と --prompt が揃っている" \
  'orca worktree create --repo path:/tmp/repo --name issue-1 --base-branch main --issue 1 --agent claude --prompt "実装しろ" --json'
run_case pass "= 区切りで揃っている" \
  'orca worktree create --repo path:/tmp/repo --name issue-1 --agent=claude --prompt="実装しろ"'
run_case pass "worktree list" 'orca worktree list --json'
run_case pass "worktree rm" 'orca worktree rm --worktree path:/tmp/wt --json'
run_case pass "terminal create" \
  'orca terminal create --worktree path:/tmp/wt --title t --command "claude" --json'
run_case pass "git worktree add --detach" 'git worktree add --detach ../nt-tools-docs'
run_case pass "クォートの中に書くだけ（PR 本文）" \
  "gh pr comment 1 --body 'orca worktree create には --agent と --prompt を付けろ'"
run_case pass "クォートの中に書くだけ（コミットメッセージ）" \
  'git commit -m "feat: orca worktree create を --agent 無しで叩けなくする"'
run_case pass "grep するだけ" "grep -rn 'orca worktree create' ./plugins"

if [[ "$failures" -gt 0 ]]; then
  printf '\norca-worktree-agent-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'orca-worktree-agent-gate: %d 件すべて期待どおり\n' "$total"
