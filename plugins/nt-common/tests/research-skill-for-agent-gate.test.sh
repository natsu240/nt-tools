#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-research-skill-for-agent.sh"
[[ -f "$HOOK" ]] || { echo "deny-research-skill-for-agent.sh が見つかりません: $HOOK"; exit 1; }

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
  local expected=$1 label=$2 prompt=$3 subagent=${4:-general-purpose} extra=${5:-'{}'}
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg p "$prompt" --arg s "$subagent" --argjson extra "$extra" \
    '{tool_name: "Agent", tool_input: {prompt: $p, subagent_type: $s}} + $extra' | bash "$HOOK" 2>&1)"
  actual="$(classify "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 調査キーワード + 外部ソースキーワードの両方 → 拒否 ---
run_case deny "両方のキーワードを含む" "このAPIについて調査して。公式ドキュメントを確認して"

# --- 片方のキーワードだけ → 素通し ---
run_case pass "調査キーワードのみ" "このAPIについて調査して"
run_case pass "外部ソースキーワードのみ" "公式ドキュメントを読んで"

# --- 止めてはいけない例: 共有ドキュメントツールの調査・検索 → 素通し ---
run_case pass "スプレッドシートを調査する委譲" "この障害の記録をスプレッドシートで調査して。公式ドキュメントの引用があれば拾って"
run_case pass "Google Drive の資料を確認する委譲" "Google Drive の資料を調査して。一次ソースとして本文をそのまま持ってきて"
run_case pass "Sheets の一次ソース確認" "Sheets の値を調査して。公式ドキュメントの引用があれば一次ソースとして拾って"

# --- 止めてはいけない例: 検索という語だけで外部ウェブを指していない → 素通し ---
run_case pass "コードを検索する委譲" "このリポジトリ配下を検索して、該当の実装を調査して"

# --- 止めてはいけない例: ローカルコードの調査 → 素通し ---
run_case pass "ローカルのパスを読む調査" "対象テーブルのデータモデルを調査して。backend/database/migrations/ と backend/app/Models/ を Read して一次ソースの定義をまとめろ"
run_case pass "外部アクセス禁止を明記した調査" "対象テーブルのデータモデルを調査して。外部URLへのアクセス（WebFetch/WebSearch）は一切行うな"
run_case pass "ローカルファイルのみと明記した調査" "この仕様を調査して。ローカルファイルの Read のみで完結させろ"
run_case pass "公式ドキュメントの写しをリポジトリ内で読む調査" "リポジトリ内に取り込んだ公式ドキュメントを調査して"

# --- 共有ドキュメントツールに触れない外部ウェブ調査 → 拒否のまま ---
run_case deny "外部ウェブの一次ソース調査" "この仕様について調査して。一次ソースをウェブで確認して"

# --- claude-code-guide への委譲 → 素通し ---
run_case pass "claude-code-guide は対象外" "このAPIについて調査して。公式ドキュメントを確認して" claude-code-guide

# --- サブエージェント配下からの Agent 呼び出し → 素通し ---
run_case pass "サブエージェント配下は対象外" "このAPIについて調査して。公式ドキュメントを確認して" general-purpose '{"agent_id": "a1", "agent_type": "explorer"}'

if [[ "$failures" -gt 0 ]]; then
  printf '\nresearch-skill-for-agent-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'research-skill-for-agent-gate: %d 件すべて期待どおり\n' "$total"
