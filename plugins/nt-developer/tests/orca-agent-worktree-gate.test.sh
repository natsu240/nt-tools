#!/usr/bin/env bash

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/gate-orca-agent-worktree.sh"
[[ -f "$HOOK" ]] || { echo "gate-orca-agent-worktree.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

classify() {
  if [[ -z "$1" ]]; then
    echo pass
  elif grep -q '"permissionDecision": "ask"' <<<"$1"; then
    echo ask
  else
    echo other
  fi
}

run_case() {
  local expected=$1 label=$2 cmd=$3
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
  actual="$(classify "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    printf '    出力: %s\n' "$out"
  fi
}

# --- 止める例 ---
run_case ask "--agent 付きの orca worktree create" \
  'orca worktree create --repo path:/x --name y --base-branch main --agent claude --prompt "実装しろ"'
run_case ask "--agent=claude の等号形式" \
  'orca worktree create --repo path:/x --name y --base-branch main --agent=claude --prompt "実装しろ"'
run_case ask "&& の後ろの --agent 付き create" \
  'git fetch origin && orca worktree create --repo path:/x --name y --agent claude --prompt "実装しろ"'

# --- 止めてはいけない例 ---
run_case pass "--agent 無しの orca worktree create" \
  'orca worktree create --repo path:/x --name y --base-branch main'
run_case pass "--agent がクォート内の本文にだけ現れる" \
  'orca worktree create --repo path:/x --name y --prompt "--agent claude と書いてある本文"'
run_case pass "orca worktree rm" 'orca worktree rm --worktree path:/x'
run_case pass "orca worktree list" 'orca worktree list --json'
run_case pass "create を grep するだけ" "grep -rn 'orca worktree create --agent' ./docs"

if [[ "$failures" -gt 0 ]]; then
  printf '\norca-agent-worktree-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'orca-agent-worktree-gate: %d 件すべて期待どおり\n' "$total"
