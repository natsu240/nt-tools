#!/usr/bin/env bash
# deny-git-skill.sh の検査。
# gh pr comment（review を伴わない単独コマンド）が pr-review カテゴリの正規表現から漏れておらず、pr-comment skill 未起動なら deny されるかを確認する。

set -uo pipefail

HOOKS_DIR="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)"
HOOK="$HOOKS_DIR/deny-git-skill.sh"
[[ -f "$HOOK" ]] || { echo "deny-git-skill.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/hook-state"

EMPTY_TRANSCRIPT="$TMP_ROOT/empty.jsonl"
: >"$EMPTY_TRANSCRIPT"

CALLED_TRANSCRIPT="$TMP_ROOT/called.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "nt-developer:pr-comment"}}]}}' >"$CALLED_TRANSCRIPT"

failures=0
total=0

judge() {
  local out=$1
  if [[ -z "$out" ]]; then
    printf 'pass'
  elif grep -q '"permissionDecision": "deny"' <<<"$out"; then
    printf 'deny'
  else
    printf 'other'
  fi
}

run_case() {
  local expected=$1 label=$2 command=$3 session=$4 transcript=${5:-$EMPTY_TRANSCRIPT}
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg c "$command" --arg s "$session" --arg t "$transcript" \
    '{tool_name: "Bash", tool_input: {command: $c}, session_id: $s, transcript_path: $t}' \
    | HOME="$FAKE_HOME" bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-4s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- gh pr comment 単独(review を伴わない)は漏れていた穴 ---
run_case deny "gh pr comment 未起動" "gh pr comment 123 --body 'x'" no-skill
run_case pass "gh pr comment は pr-comment 起動済みなら通る" "gh pr comment 123 --body 'x'" ready "$CALLED_TRANSCRIPT"

# --- 既存の gh pr review も引き続き対象 ---
run_case deny "gh pr review 未起動" "gh pr review 123 --approve --body 'x'" no-skill
run_case pass "gh pr review は pr-comment 起動済みなら通る" "gh pr review 123 --approve --body 'x'" ready "$CALLED_TRANSCRIPT"

# --- 対象外のコマンド ---
run_case pass "gh pr view は対象外" "gh pr view 123" no-skill
run_case pass "gh pr comment という文字列を含む grep は対象外" "grep -rn 'gh pr comment' ." no-skill

if [[ "$failures" -gt 0 ]]; then
  printf '\ngit-skill-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'git-skill-gate: %d 件すべて期待どおり\n' "$total"
