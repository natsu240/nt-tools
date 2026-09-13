#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/warn-repeat-denial.py"
[[ -f "$HOOK" ]] || { echo "warn-repeat-denial.py が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

transcript="$(mktemp)"
trap 'rm -f "$transcript"' EXIT

write_transcript() {
  local content=$1
  printf '%s' "$content" >"$transcript"
}

# permissionDecision が allow かつ reason 付きなら "escalate"、それ以外は "pass"。
run_case() {
  local expected=$1 label=$2 cmd=$3
  local out rc actual reason
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" --arg t "$transcript" '{tool_name: "Bash", tool_input: {command: $c}, transcript_path: $t}' | python3 "$HOOK" 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    actual="rc=$rc"
  else
    reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$out" 2>/dev/null)"
    if grep -qF '拒否されています' <<<"$reason"; then
      actual="escalate"
    else
      actual="pass"
    fi
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-9s 実際=%-9s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    printf '    出力: %s\n' "$out"
  fi
}

# --- 同一ファイル(basename一致)への操作が直近2回拒否済み → 3回目で警告 ---
write_transcript '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"grep -n foo /path/to/example.txt"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"head -50 /other/dir/example.txt"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true}]}}'
run_case escalate "書き方を変えても同一basenameなら検知する" "sed -n '1,5p' /yet/another/example.txt"

# --- 無関係なファイルへの操作は検知しない ---
run_case pass "無関係なファイルなら検知しない" 'grep -n bar /completely/unrelated/other.txt'

# --- 拒否されていない(is_error=false)履歴は数えない ---
write_transcript '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"grep -n foo /path/to/example.txt"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"head -50 /other/dir/example.txt"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":false}]}}'
run_case pass "成功済みの履歴は拒否回数に数えない" "sed -n '1,5p' /yet/another/example.txt"

# --- ES への curl が連続で拒否されても URL の basename を同一ファイルと誤認しない ---
write_transcript '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"curl -s \"http://localhost:9200/logs-generic.otel-default/_search\" -H \"Content-Type: application/json\" -d @<(cat <<EOF\n{}\nEOF\n)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"curl -s \"http://localhost:9200/logs-generic.otel-default/_count?pretty\" -d @<(cat <<EOF\n{}\nEOF\n)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true}]}}'
run_case pass "ES への curl が連続拒否されても URL の basename では検知しない" 'curl -s "http://localhost:9200/logs-generic.otel-default/_search" -d @<(cat <<EOF
{}
EOF
)'

# --- 同一ファイルへの操作が繰り返し拒否されたときは、URL 除外を入れても今まで通り検知する ---
write_transcript '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"grep -n foo /path/to/example.txt"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"head -50 /other/dir/example.txt"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true}]}}'
run_case escalate "URL 除外を入れても同一ファイルの繰り返し拒否は今も検知する" "sed -n '1,5p' /yet/another/example.txt"

# --- 閾値未満(1回だけ拒否)は検知しない ---
write_transcript '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"grep -n foo /path/to/example.txt"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true}]}}'
run_case pass "拒否1回だけでは閾値未満" "sed -n '1,5p' /yet/another/example.txt"

if [[ "$failures" -gt 0 ]]; then
  printf '\nrepeat-denial-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'repeat-denial-gate: %d 件すべて期待どおり\n' "$total"
