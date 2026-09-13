#!/usr/bin/env bash
# deny-otel-analysis-skill.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-otel-analysis-skill.sh"
[[ -f "$HOOK" ]] || { echo "deny-otel-analysis-skill.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/hook-state"

EMPTY_TRANSCRIPT="$TMP_ROOT/empty.jsonl"
: >"$EMPTY_TRANSCRIPT"

CALLED_TRANSCRIPT="$TMP_ROOT/called.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "nt-common:otel-analysis"}}]}}' >"$CALLED_TRANSCRIPT"

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

run_raw_case() {
  local expected=$1 label=$2 payload=$3 env_prefix=${4:-}
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | HOME="$FAKE_HOME" env $env_prefix bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-4s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- Elasticsearch への集計コマンド ---
run_raw_case deny "localhost:9200 未起動" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Bash", tool_input: {command: "curl -s \"http://localhost:9200/logs-generic.otel-default/_search\""}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case pass "localhost:9200 は起動済みなら通る" "$(jq -nc --arg t "$CALLED_TRANSCRIPT" '{tool_name: "Bash", tool_input: {command: "curl -s \"http://localhost:9200/logs-generic.otel-default/_search\""}, session_id: "ready", transcript_path: $t}')"
run_raw_case deny "127.0.0.1:9200 未起動" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Bash", tool_input: {command: "curl -s http://127.0.0.1:9200/_count"}, session_id: "no-skill", transcript_path: $t}')"

# --- 対象外のコマンド ---
run_raw_case pass "9200 を含まないコマンドは対象外" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Bash", tool_input: {command: "curl -s http://localhost:5601/api/status"}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case pass "git status は対象外" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Bash", tool_input: {command: "git status"}, session_id: "no-skill", transcript_path: $t}')"

# --- otel-analysis の claude -p サブプロセス自身の呼び出しは対象外 ---
run_raw_case pass "NT_OTEL_ANALYSIS_SUBPROCESS 環境変数あり" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Bash", tool_input: {command: "curl -s http://localhost:9200/_count"}, session_id: "no-skill", transcript_path: $t}')" "NT_OTEL_ANALYSIS_SUBPROCESS=1"

# --- 対象外のツール ---
run_raw_case pass "対象外ツール(Read)" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Read", tool_input: {file_path: "/repo/a.md"}, session_id: "no-skill", transcript_path: $t}')"

if [[ "$failures" -gt 0 ]]; then
  printf '\notel-analysis-skill-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'otel-analysis-skill-gate: %d 件すべて期待どおり\n' "$total"
