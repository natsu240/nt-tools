#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-pr-assignee.sh"
[[ -f "$HOOK" ]] || { echo "deny-pr-assignee.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

run_case() {
  local expected=$1 label=$2 cmd=$3
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
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
    printf '    コマンド: %s\n' "$cmd"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- assignee 無しの gh pr create → 拒否 ---
run_case deny "assignee 無し" 'gh pr create --title "foo"'

# --- assignee ありの gh pr create → 素通し ---
run_case pass "--assignee で指定" 'gh pr create --title "foo" --assignee @me'
run_case pass "-a で指定" 'gh pr create --title "foo" -a @me'
run_case pass "--assignee= で指定" 'gh pr create --title "foo" --assignee=@me'

# --- gh pr create 以外は対象外 → 素通し ---
run_case pass "gh pr edit は対象外" 'gh pr edit 123 --add-assignee @me'

# --- クォート内の文字列として現れるだけ → 素通し ---
run_case pass "コミットメッセージに書く" "git commit -m 'gh pr create を直した'"

if [[ "$failures" -gt 0 ]]; then
  printf '\npr-assignee-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'pr-assignee-gate: %d 件すべて期待どおり\n' "$total"
