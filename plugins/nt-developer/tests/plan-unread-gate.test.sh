#!/usr/bin/env bash
# warn-plan-unread-before-pr.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/warn-plan-unread-before-pr.sh"
[[ -f "$HOOK" ]] || { echo "warn-plan-unread-before-pr.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/hook-state"
printf '%s\n' "/home/user/app/plans/進行中/github/計画.md" >"$FAKE_HOME/.claude/hook-state/plan-read_reads.log"
printf '%s\n' "/home/user/app/src/Foo.php" >"$FAKE_HOME/.claude/hook-state/plan-unread_reads.log"

read_call() {
  jq -cn --arg f "$1" '{type: "assistant", message: {content: [{type: "tool_use", id: "x", name: "Read", input: {file_path: $f}}]}}'
}

write_call() {
  jq -cn --arg f "$1" '{type: "assistant", message: {content: [{type: "tool_use", id: "x", name: "Write", input: {file_path: $f}}]}}'
}

bash_call() {
  jq -cn --arg c "$1" '{type: "assistant", message: {content: [{type: "tool_use", id: "x", name: "Bash", input: {command: $c}}]}}'
}

skill_call() {
  jq -cn --arg s "$1" '{type: "assistant", message: {content: [{type: "tool_use", id: "x", name: "Skill", input: {skill: $s}}]}}'
}

PLAN_READ="$TMP_ROOT/plan-read.jsonl"
read_call '/home/user/app/plans/進行中/github/計画.md' >"$PLAN_READ"

ISSUE_READ="$TMP_ROOT/issue-read.jsonl"
bash_call 'gh issue view 601 --json body --jq .body' >"$ISSUE_READ"

NOTHING_READ="$TMP_ROOT/nothing-read.jsonl"
read_call '/home/user/app/src/Foo.php' >"$NOTHING_READ"

PLAN_NOT_LAUNCHED="$NOTHING_READ"

PLAN_LAUNCHED_NO_DOC="$TMP_ROOT/plan-launched-no-doc.jsonl"
{
  skill_call 'nt-developer:plan'
  read_call '/home/user/app/src/Foo.php'
} >"$PLAN_LAUNCHED_NO_DOC"

PLAN_WRITTEN_UNREAD="$TMP_ROOT/plan-written-unread.jsonl"
{
  skill_call 'nt-developer:plan'
  write_call '/home/user/app/plans/進行中/github/計画.md'
} >"$PLAN_WRITTEN_UNREAD"

ISSUE_CREATED_UNREAD="$TMP_ROOT/issue-created-unread.jsonl"
{
  skill_call 'plan'
  bash_call 'gh issue create --title "x" --body "y"'
} >"$ISSUE_CREATED_UNREAD"

PLAN_WRITTEN_READ="$TMP_ROOT/plan-written-read.jsonl"
{
  skill_call 'nt-developer:plan'
  write_call '/home/user/app/plans/進行中/github/計画.md'
  read_call '/home/user/app/plans/進行中/github/計画.md'
} >"$PLAN_WRITTEN_READ"

failures=0
total=0

run_case() {
  local expected=$1 label=$2 skill=$3 session=$4 transcript=$5
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg s "$skill" --arg sid "$session" --arg t "$transcript" \
    '{tool_name: "Skill", tool_input: {skill: $s}, session_id: $sid, transcript_path: $t}' \
    | HOME="$FAKE_HOME" bash "$HOOK" 2>&1)"
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

# --- 計画書を作成したのに読んでいない → deny ---
run_case deny "plan書き込み後・commit skill" nt-developer:commit plan-unread "$PLAN_WRITTEN_UNREAD"
run_case deny "plan書き込み後・pr skill" pr plan-unread "$PLAN_WRITTEN_UNREAD"
run_case deny "gh issue create後・pr-followup skill" nt-developer:pr-followup plan-unread "$ISSUE_CREATED_UNREAD"

# --- 止めてはいけない例 ---
run_case pass "計画書を Read 済み（会話ログ）" nt-developer:commit plan-unread "$PLAN_WRITTEN_READ"
run_case pass "計画書を Read 済み（記録ファイル）" nt-developer:commit plan-read "$NOTHING_READ"
run_case pass "Issue の description を取得済み" nt-developer:commit plan-unread "$ISSUE_READ"
run_case pass "対象外の skill" nt-developer:plan plan-unread "$PLAN_WRITTEN_UNREAD"
run_case pass "判定材料が何も無い" nt-developer:commit "" "$TMP_ROOT/missing.jsonl"
run_case pass "plan未起動" nt-developer:commit plan-unread "$PLAN_NOT_LAUNCHED"
run_case pass "plan起動済みだが計画書非作成" nt-developer:commit plan-unread "$PLAN_LAUNCHED_NO_DOC"

if [[ "$failures" -gt 0 ]]; then
  printf '\nplan-unread-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'plan-unread-gate: %d 件すべて期待どおり\n' "$total"
