#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-agent-selection.sh"
[[ -f "$HOOK" ]] || { echo "deny-agent-selection.sh が見つかりません: $HOOK"; exit 1; }

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

run_raw_case() {
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(bash "$HOOK" <<<"$payload" 2>&1)"
  actual="$(classify "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

run_case() {
  local expected=$1 label=$2 subagent=$3 extra=${4:-'{}'}
  run_raw_case "$expected" "$label" \
    "$(jq -cn --arg s "$subagent" --argjson extra "$extra" \
      '{tool_name: "Agent", tool_input: {prompt: "調べろ", subagent_type: $s}} + $extra')"
}

# --- 汎用タイプ → 拒否 ---
run_case deny "claude（汎用の受け皿）" claude
run_case deny "general-purpose" general-purpose
run_case deny "Explore" Explore
run_case deny "大文字混じりの Claude" Claude
run_case deny "大文字混じりの General-Purpose" General-Purpose

# --- 汎用タイプはサブエージェント配下でも拒否 ---
run_case deny "サブエージェント配下の claude" claude '{"agent_id": "a1", "agent_type": "nt-common:explorer"}'

# --- subagent_type 未指定 → 拒否 ---
run_raw_case deny "subagent_type キーが無い" '{"tool_name": "Agent", "tool_input": {"prompt": "調べろ"}}'
run_case deny "subagent_type が空文字" ""

# --- 専用エージェント → 素通し（誤検知するとここが止まる） ---
run_case pass "nt-common:explorer" nt-common:explorer
run_case pass "nt-common:skimmer" nt-common:skimmer
run_case pass "nt-developer:reviewer" nt-developer:reviewer
run_case pass "組み込みの Plan" Plan
run_case pass "組み込みの statusline-setup" statusline-setup
run_case pass "名前に claude を含む専用エージェント" claude-code-guide
run_case pass "サブエージェント配下の explorer" nt-common:explorer '{"agent_id": "a1", "agent_type": "nt-common:explorer"}'

# --- Agent 以外のツール → 素通し ---
run_raw_case pass "Task ツールは対象外" '{"tool_name": "Task", "tool_input": {"subagent_type": "claude"}}'
run_raw_case pass "Read は対象外" '{"tool_name": "Read", "tool_input": {"file_path": "/tmp/foo.md"}}'

if [[ "$failures" -gt 0 ]]; then
  printf '\nagent-selection-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'agent-selection-gate: %d 件すべて期待どおり\n' "$total"
