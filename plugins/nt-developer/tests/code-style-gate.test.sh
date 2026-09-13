#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/gate-code-style-skill.sh"
[[ -f "$HOOK" ]] || { echo "gate-code-style-skill.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
FAKE_TMPDIR="$TMP_ROOT/tmpdir"
mkdir -p "$FAKE_HOME/.claude/hook-state" "$FAKE_TMPDIR"

# 中身が空でもファイルとして実在させないと hook が会話ログを読まずに素通しする。
EMPTY_TRANSCRIPT="$TMP_ROOT/empty.jsonl"
: >"$EMPTY_TRANSCRIPT"

# 会話ログ側だけで code-style 起動済みを表した形（skills.log は無い）。
CALLED_TRANSCRIPT="$TMP_ROOT/called.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "nt-developer:code-style"}}]}}' >"$CALLED_TRANSCRIPT"

STATE="$FAKE_HOME/.claude/hook-state"
printf 'nt-developer:code-style\n' >"$STATE/common_skills.log"
printf 'code-style\n' >"$STATE/short-name_skills.log"
printf 'nt-developer:code-style-laravel\n' >"$STATE/laravel-only_skills.log"
printf 'nt-developer:code-style\nnt-developer:code-style-laravel\n' >"$STATE/php-ready_skills.log"
printf 'nt-developer:past-plan-research\n' >"$STATE/other-skill_skills.log"
printf 'nt-developer:code-style\nnt-developer:code-style-ts\n' >"$STATE/ts-ready_skills.log"
printf 'nt-developer:code-style\nnt-developer:code-style-cdk\nnt-developer:code-style-ts\n' >"$STATE/cdk-ready_skills.log"

failures=0
total=0

classify() {
  if [[ -z "$1" ]]; then
    echo pass
  elif grep -q '"permissionDecision": "deny"' <<<"$1"; then
    echo deny
  else
    echo other
  fi
}

run_case() {
  local expected=$1 label=$2 path=$3 session=$4 transcript=${5:-$EMPTY_TRANSCRIPT}
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg p "$path" --arg s "$session" --arg t "$transcript" \
    '{tool_name: "Edit", tool_input: {file_path: $p}, session_id: $s, transcript_path: $t}' \
    | HOME="$FAKE_HOME" TMPDIR="$FAKE_TMPDIR" bash "$HOOK" 2>&1)"
  actual="$(classify "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-5s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    ファイル: %s  セッション: %s\n' "$path" "$session"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

run_raw_case() {
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | HOME="$FAKE_HOME" TMPDIR="$FAKE_TMPDIR" bash "$HOOK" 2>&1)"
  actual="$(classify "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-5s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

SH_PATH="/home/user/project/hooks/guard.sh"

# --- シェルスクリプトは code-style を要求する ---
run_case deny "未起動での .sh 編集" "$SH_PATH" no-skill
run_case deny "未起動での .bash 編集" "/home/user/project/bin/run.bash" no-skill
run_case deny "未起動での .zsh 編集" "/home/user/project/bin/run.zsh" no-skill
run_case deny "別の skill だけ起動済み" "$SH_PATH" other-skill
run_case pass "skills.log で起動済み" "$SH_PATH" common
run_case pass "短縮名で起動済み" "$SH_PATH" short-name
run_case pass "会話ログで起動済み" "$SH_PATH" no-skill "$CALLED_TRANSCRIPT"

# シェルスクリプト固有の規約をまとめた領域別 skill は無いため、code-style 単体で足りる。
run_case pass "領域別 skill を追加で要求しない" "$SH_PATH" common

# --- 領域別 skill が要る拡張子との差を固定する ---
run_case deny "PHP は code-style だけでは通らない" "/home/user/project/src/Foo.php" common
run_case pass "PHP は laravel も起動済みなら通る" "/home/user/project/src/Foo.php" php-ready
run_case deny "PHP で領域別だけ起動していても通らない" "/home/user/project/src/Foo.php" laravel-only

# --- infra 配下の .ts は code-style / code-style-cdk / code-style-ts の3つだけを要求する ---
run_case pass "infra 配下は3つ揃えば通る" "/home/user/project/infra/lib/rds-stack.ts" cdk-ready
run_case deny "infra 配下で cdk が欠けていれば止まる" "/home/user/project/infra/lib/rds-stack.ts" ts-ready
run_case pass "infra 配下でない .ts は cdk を要求しない" "/home/user/project/src/api/client.ts" ts-ready

# --- 止めてはいけないもの → 素通し ---
run_case pass "Markdown は対象外" "/home/user/project/README.md" no-skill
run_case pass "テキストは対象外" "/home/user/project/notes.txt" no-skill
run_case pass "拡張子なしは対象外" "/home/user/project/Makefile" no-skill
run_case pass "/tmp 配下の .sh" "/tmp/scratch/aggregate.sh" no-skill
run_case pass "/private/tmp 配下の .sh" "/private/tmp/claude-501/x/aggregate.sh" no-skill
run_case pass "TMPDIR 配下の .sh" "$FAKE_TMPDIR/aggregate.sh" no-skill
run_case pass "会話ログが実在しないときは判定しない" "$SH_PATH" no-skill "$TMP_ROOT/missing.jsonl"

# --- 対象外のツール・入力 ---
run_raw_case pass "対象外ツール（Read）" "$(jq -cn --arg p "$SH_PATH" --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Read", tool_input: {file_path: $p}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case pass "対象外ツール（Bash）" "$(jq -cn --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Bash", tool_input: {command: "bash guard.sh"}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case pass "file_path が無い" "$(jq -cn --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Edit", tool_input: {}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case deny "Write も対象" "$(jq -cn --arg p "$SH_PATH" --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Write", tool_input: {file_path: $p}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case deny "MultiEdit も対象" "$(jq -cn --arg p "$SH_PATH" --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "MultiEdit", tool_input: {file_path: $p}, session_id: "no-skill", transcript_path: $t}')"

if [[ "$failures" -gt 0 ]]; then
  printf '\ncode-style-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'code-style-gate: %d 件すべて期待どおり\n' "$total"
