#!/usr/bin/env bash
# deny-cd-in-bash.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-cd-in-bash.sh"
[[ -f "$HOOK" ]] || { echo "deny-cd-in-bash.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

run_case() {
  local expected=$1 label=$2 cmd=$3
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
  if [[ -z "$out" ]]; then
    actual="pass"
  elif grep -qE '"permissionDecision":[[:space:]]*"deny"' <<<"$out"; then
    actual="deny"
  else
    actual="other"
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 実行される位置の cd → 止める ---
run_case deny "単体の cd" 'cd /home/user/project'
run_case deny "&& でつないだ cd" 'cd /home/user/project && git status'
run_case deny "; でつないだ cd" 'ls; cd /tmp'
run_case deny "サブシェルの cd" '(cd /home/user/project && git status)'
run_case deny "コマンド置換の中の cd" 'root=$(cd /home/user && pwd)'
run_case deny "引数無しの cd" 'cd && ls'

# --- 止めてはいけない例 ---
run_case pass "cd で始まる別コマンド" 'cdk deploy MyStack'
run_case pass "クォート内の cd" 'echo "cd /tmp してはいけない"'
run_case pass "コミットメッセージの中の cd" "git commit -m 'cd の使用を禁止した'"
run_case pass "引数として現れる cd" 'find . -name cd'
run_case pass "オプション名に含まれる cd" 'rsync --checksum src dst'
run_case pass "git -C での指定" 'git -C /home/user/project status'
run_case pass "cd を含まない通常のコマンド" 'ls -la /home/user/project'

if [[ "$failures" -gt 0 ]]; then
  printf '\ncd-in-bash-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'cd-in-bash-gate: %d 件すべて期待どおり\n' "$total"
