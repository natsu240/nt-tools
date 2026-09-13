#!/usr/bin/env bash
# deny-git-add-before-commit.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-git-add-before-commit.sh"
[[ -f "$HOOK" ]] || { echo "deny-git-add-before-commit.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

bash_call() {
  jq -cn --arg id "$1" --arg c "$2" \
    '{type: "assistant", message: {content: [{type: "tool_use", id: $id, name: "Bash", input: {command: $c}}]}}'
}

tool_result() {
  jq -cn --arg id "$1" --argjson err "$2" \
    '{type: "user", message: {content: [{type: "tool_result", tool_use_id: $id, is_error: $err}]}}'
}

FAILED_ADD="$TMP_ROOT/failed-add.jsonl"
{ bash_call a1 'git add plugins/foo.sh'; tool_result a1 true; } >"$FAILED_ADD"

OK_ADD="$TMP_ROOT/ok-add.jsonl"
{ bash_call a1 'git add plugins/foo.sh'; tool_result a1 false; } >"$OK_ADD"

RECOVERED_ADD="$TMP_ROOT/recovered-add.jsonl"
{
  bash_call a1 'git add plugins/foo.sh'; tool_result a1 true
  bash_call a2 'git add plugins/foo.sh'; tool_result a2 false
} >"$RECOVERED_ADD"

QUOTED_ADD="$TMP_ROOT/quoted-add.jsonl"
{ bash_call a1 "gh pr comment 1 --body 'git add に失敗していた'"; tool_result a1 true; } >"$QUOTED_ADD"

NO_ADD="$TMP_ROOT/no-add.jsonl"
{ bash_call a1 'git status --porcelain'; tool_result a1 true; } >"$NO_ADD"

failures=0
total=0

run_case() {
  local expected=$1 label=$2 cmd=$3 transcript=$4
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg c "$cmd" --arg t "$transcript" '{tool_name: "Bash", tool_input: {command: $c}, transcript_path: $t}' | bash "$HOOK" 2>&1)"
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
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 直前の git add が失敗している → deny ---
run_case deny "失敗した git add の直後のコミット" 'git commit -m "修正"' "$FAILED_ADD"

# --- 止めてはいけない例 ---
run_case pass "git add が成功している" 'git commit -m "修正"' "$OK_ADD"
run_case pass "失敗後にやり直して成功している" 'git commit -m "修正"' "$RECOVERED_ADD"
run_case pass "git add をまだ実行していない" 'git commit -m "修正"' "$NO_ADD"
run_case pass "失敗したのは git add ではなく本文に書かれただけ" 'git commit -m "修正"' "$QUOTED_ADD"
run_case pass "コミット以外のコマンド" 'git push origin HEAD' "$FAILED_ADD"
run_case pass "コミットメッセージに git commit と書くだけ" "gh pr comment 1 --body 'git commit の前に確認しろ'" "$FAILED_ADD"
run_case pass "会話ログが無い" 'git commit -m "修正"' "$TMP_ROOT/missing.jsonl"

if [[ "$failures" -gt 0 ]]; then
  printf '\ngit-add-before-commit-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'git-add-before-commit-gate: %d 件すべて期待どおり\n' "$total"
