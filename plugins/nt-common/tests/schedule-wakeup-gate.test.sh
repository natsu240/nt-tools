#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-schedule-wakeup.sh"
[[ -f "$HOOK" ]] || { echo "deny-schedule-wakeup.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

run_case() {
  local expected=$1 label=$2 tool_input=$3
  local out actual
  total=$((total + 1))
  out="$(jq -n --argjson i "$tool_input" '{tool_name: "ScheduleWakeup", tool_input: $i}' | bash "$HOOK" 2>&1)"
  if [[ -z "$out" ]]; then
    actual="pass"
  elif grep -q '"permissionDecision": "deny"' <<<"$out"; then
    actual="deny"
  else
    actual="other"
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    入力: %s\n' "$tool_input"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 次のターンの予約 → 拒否 ---
run_case deny "サブエージェントの完了待ち" '{"delaySeconds":600,"noop":true,"prompt":"続きをやれ","reason":"サブエージェントの完了待ち"}'
run_case deny "prompt 無しの失敗する呼び出し" '{"delaySeconds":60,"noop":true}'
run_case deny "/loop の動的モードの予約" '{"delaySeconds":1800,"noop":false,"prompt":"<<autonomous-loop-dynamic>>","reason":"定期確認"}'
run_case deny "tool_input が空" '{}'
run_case deny "stop が false" '{"stop":false,"delaySeconds":120,"noop":true,"prompt":"x","reason":"y"}'

# --- /loop の終了 → 素通し（止めてはいけない例） ---
run_case pass "stop: true で loop を終わらせる" '{"stop":true}'

if [[ "$failures" -gt 0 ]]; then
  printf '\nschedule-wakeup-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'schedule-wakeup-gate: %d 件すべて期待どおり\n' "$total"
