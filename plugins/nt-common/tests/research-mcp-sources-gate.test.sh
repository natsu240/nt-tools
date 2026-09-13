#!/usr/bin/env bash
# deny-research-for-mcp-sources.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-research-for-mcp-sources.sh"
[[ -f "$HOOK" ]] || { echo "deny-research-for-mcp-sources.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

run_case() {
  local expected=$1 label=$2 skill=$3 args=$4
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg s "$skill" --arg a "$args" '{tool_name: "Skill", tool_input: {skill: $s, args: $a}}' | bash "$HOOK" 2>&1)"
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

# --- 専用 MCP で読める情報源 → 拒否 ---
run_case deny "Google スプレッドシート" research 'https://docs.google.com/spreadsheets/d/abc/edit の項目一覧'
run_case deny "Google ドライブ" research 'https://drive.google.com/file/d/abc/view の中身'

# --- 止めてはいけない例 ---
run_case pass "公開ドキュメントの調査" research 'https://docs.anthropic.com/ja/docs/claude-code/hooks の仕様を調べて'
run_case pass "URL を含まない調査テーマ" research 'launchd の plist で環境変数を渡す方法'
run_case pass "GitHub の調査" research 'https://github.com/anthropics/claude-code の issue を調べて'
run_case pass "別の skill" nt-developer:plan 'https://docs.google.com/spreadsheets/d/abc/edit を見て計画を立てて'
run_case pass "調査テーマが空" research ''

if [[ "$failures" -gt 0 ]]; then
  printf '\nresearch-mcp-sources-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'research-mcp-sources-gate: %d 件すべて期待どおり\n' "$total"
