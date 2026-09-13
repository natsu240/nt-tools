#!/usr/bin/env bash
# warn-rebase-drop.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/warn-rebase-drop.sh"
[[ -f "$HOOK" ]] || { echo "warn-rebase-drop.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

bash_call() {
  jq -cn --arg c "$1" '{type: "assistant", message: {content: [{type: "tool_use", id: "x", name: "Bash", input: {command: $c}}]}}'
}

NO_SHOW="$TMP_ROOT/no-show.jsonl"
bash_call 'git log --oneline' >"$NO_SHOW"

WITH_SHOW="$TMP_ROOT/with-show.jsonl"
bash_call 'git show 1bfff961 --stat' >"$WITH_SHOW"

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
    printf '    コマンド: %s\n' "$cmd"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- drop を指定する対話的リベースで、git show による確認が無い → deny ---
run_case deny "sed で pick を drop に書き換える・未確認" \
  "GIT_SEQUENCE_EDITOR=\"sed -i '' 's/^pick 1bfff961/drop 1bfff961/'\" git rebase -i HEAD~5" "$NO_SHOW"
run_case deny "先頭が git rebase でない形・未確認" \
  "git fetch origin && GIT_SEQUENCE_EDITOR='sed -i s/pick/drop/' git rebase -i origin/main" "$NO_SHOW"

# --- 止めてはいけない例 ---
run_case pass "git show で確認済み" \
  "GIT_SEQUENCE_EDITOR=\"sed -i '' 's/^pick 1bfff961/drop 1bfff961/'\" git rebase -i HEAD~5" "$WITH_SHOW"
run_case pass "drop を伴わない対話的リベース" \
  "GIT_SEQUENCE_EDITOR='sed -i s/pick/squash/' git rebase -i HEAD~3" "$NO_SHOW"
run_case pass "通常のリベース" 'git rebase origin/develop' "$NO_SHOW"
run_case pass "リベースの継続" 'git rebase --continue' "$NO_SHOW"
run_case pass "コミットメッセージに drop と書く" "git commit -m 'drop 判断の誤りを直した'" "$NO_SHOW"
run_case pass "rebase を伴わない GIT_SEQUENCE_EDITOR" "GIT_SEQUENCE_EDITOR=vim git log --oneline" "$NO_SHOW"
run_case pass "transcript が無い" \
  "GIT_SEQUENCE_EDITOR=\"sed -i '' 's/^pick 1bfff961/drop 1bfff961/'\" git rebase -i HEAD~5" "$TMP_ROOT/missing.jsonl"

if [[ "$failures" -gt 0 ]]; then
  printf '\nrebase-drop-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'rebase-drop-gate: %d 件すべて期待どおり\n' "$total"
