#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-research-skill.sh"
[[ -f "$HOOK" ]] || { echo "deny-research-skill.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# 直近ユーザー発話が調査キーワードを含む形。
KEYWORD_TRANSCRIPT="$TMP_ROOT/keyword.jsonl"
jq -cn '{type: "user", message: {content: "これ調べて"}, timestamp: "2026-01-01T00:00:00Z"}' >"$KEYWORD_TRANSCRIPT"

# 直近ユーザー発話にキーワードが無く、以降まだ WebFetch/WebSearch を呼んでいない形。
FEW_CALLS_TRANSCRIPT="$TMP_ROOT/few-calls.jsonl"
jq -cn '{type: "user", message: {content: "これ直して"}, timestamp: "2026-01-01T00:00:00Z"}' >"$FEW_CALLS_TRANSCRIPT"

# 直近ユーザー発話にキーワードが無く、以降すでに 2 回 WebFetch を呼んでいる形（今回で 3 回目）。
MANY_CALLS_TRANSCRIPT="$TMP_ROOT/many-calls.jsonl"
{
  jq -cn '{type: "user", message: {content: "これ直して"}, timestamp: "2026-01-01T00:00:00Z"}'
  jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "WebFetch"}]}, timestamp: "2026-01-01T00:00:01Z"}'
  jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "WebSearch"}]}, timestamp: "2026-01-01T00:00:02Z"}'
} >"$MANY_CALLS_TRANSCRIPT"

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
  local expected=$1 label=$2 tool=$3 transcript=$4 extra=${5:-'{}'} env_prefix=${6:-}
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg tool "$tool" --arg t "$transcript" --argjson extra "$extra" \
    '{tool_name: $tool, transcript_path: $t} + $extra' | env $env_prefix bash "$HOOK" 2>&1)"
  actual="$(classify "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 直近発話に調査キーワード → 拒否 ---
run_case deny "調査キーワード検出" WebFetch "$KEYWORD_TRANSCRIPT"

# --- キーワード無し・呼び出し回数が閾値未満 → 素通し ---
run_case pass "キーワード無し・1回目" WebFetch "$FEW_CALLS_TRANSCRIPT"

# --- キーワード無し・3回目の呼び出し → 拒否 ---
run_case deny "回数閾値到達（3回目）" WebFetch "$MANY_CALLS_TRANSCRIPT"

# --- サブエージェント配下 → 素通し ---
run_case pass "サブエージェントは対象外" WebFetch "$KEYWORD_TRANSCRIPT" '{"agent_id": "a1", "agent_type": "nt-common:explorer"}'

# --- /research の claude -p 自身（環境変数あり）→ 素通し ---
run_case pass "NT_RESEARCH_SUBPROCESS 環境変数あり" WebFetch "$KEYWORD_TRANSCRIPT" '{}' "NT_RESEARCH_SUBPROCESS=1"

# --- 対象外ツール → 素通し ---
run_case pass "Read は対象外" Read "$KEYWORD_TRANSCRIPT"

# --- transcript_path が無い → 素通し ---
run_case pass "transcript_path 無し" WebFetch ""

if [[ "$failures" -gt 0 ]]; then
  printf '\nresearch-skill-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'research-skill-gate: %d 件すべて期待どおり\n' "$total"
