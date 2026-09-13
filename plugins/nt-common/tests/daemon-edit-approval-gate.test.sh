#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/ask-daemon-edit-approval.sh"
[[ -f "$HOOK" ]] || { echo "ask-daemon-edit-approval.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/Library/LaunchAgents"

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

run_file_case() {
  local expected=$1 label=$2 tool=$3 path=$4
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg tool "$tool" --arg p "$path" '{tool_name: $tool, tool_input: {file_path: $p}}' | HOME="$FAKE_HOME" bash "$HOOK" 2>&1)"
  actual="$(classify "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

run_bash_case() {
  local expected=$1 label=$2 cmd=$3
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | HOME="$FAKE_HOME" bash "$HOOK" 2>&1)"
  actual="$(classify "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 常駐設定への Write/Edit → 確認 ---
run_file_case ask "LaunchAgents の plist" Write "$FAKE_HOME/Library/LaunchAgents/com.foo.plist"
run_file_case ask "settings.json" Edit "$FAKE_HOME/.claude/settings.json"
run_file_case ask ".zshrc" Write "$FAKE_HOME/.zshrc"
run_file_case ask "monitor を含むファイル名" Write "$FAKE_HOME/.claude/setup-monitor-thing.sh"

# --- 通常のプロジェクトファイル → 素通し ---
run_file_case pass "通常のプロジェクトファイル" Write /home/user/project/src/Foo.php

# --- Bash 経由のリダイレクト・tee → 確認 ---
run_bash_case ask "追記リダイレクトで .zshrc" "echo x >> $FAKE_HOME/.zshrc"
run_bash_case ask "tee で settings.json" "echo x | tee $FAKE_HOME/.claude/settings.json"

# --- Bash の読み取り・通常ファイルへのリダイレクト → 素通し ---
run_bash_case pass "cat で読むだけ" "cat $FAKE_HOME/.zshrc"
run_bash_case pass "通常ファイルへのリダイレクト" 'echo x > /tmp/normal.txt'

# --- 対象外ツール → 素通し ---
run_file_case pass "Read は対象外" Read "$FAKE_HOME/.claude/settings.json"

if [[ "$failures" -gt 0 ]]; then
  printf '\ndaemon-edit-approval-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'daemon-edit-approval-gate: %d 件すべて期待どおり\n' "$total"
