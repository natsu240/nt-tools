#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-bash-background.sh"
[[ -f "$HOOK" ]] || { echo "deny-bash-background.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

run_case() {
  local expected=$1 label=$2 background=$3 cmd=$4
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" --argjson bg "$background" '{tool_name: "Bash", tool_input: {command: $c, run_in_background: $bg}}' | bash "$HOOK" 2>&1)"
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
    printf '    コマンド: %s\n' "$cmd"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 他のバックグラウンド作業/手作業の完了待ちポーリング → 拒否 ---
run_case deny "journal.jsonl を sleep でポーリング" true 'while [ ! -f journal.jsonl ]; do sleep 5; done; cat journal.jsonl'
run_case deny "pgrep でプロセス終了を待つ" true 'while pgrep -x iTerm2 >/dev/null; do sleep 5; done'
run_case deny "tasks/*.output の完成を待つ" true 'until [ -s tasks/a2e703b5.output ]; do sleep 3; done'

# --- run_in_background が true でない → 素通し（拒否対象は背景実行だけ） ---
run_case pass "run_in_background 未指定で journal.jsonl をポーリング" false 'while [ ! -f journal.jsonl ]; do sleep 5; done'
run_case pass "run_in_background が false で pgrep 待ち" false 'while pgrep -x iTerm2 >/dev/null; do sleep 5; done'

# --- 正当な背景実行 → 素通し（誤検知してはいけない例） ---
run_case pass "gh run watch での CI 待ち" true 'gh run watch 31490084919 --exit-status --interval 30'
run_case pass "gh pr checks --watch" true 'gh pr checks 273 --watch'
run_case pass "gh pr checks の until ポーリング" true 'until [ -z "$(gh pr checks 273 --json bucket --jq ".[] | select(.bucket==\"pending\")")" ]; do sleep 15; done'
run_case pass "AWS リソースの状態遷移待ち" true 'until STATUS=$(aws rds describe-db-cluster-snapshots --query "Snapshots[0].Status" --output text); [ "$STATUS" = "available" ]; do sleep 30; done'
run_case pass "npm run dev の常駐起動" true 'npm run dev'
run_case pass "単発の時刻待ち" true 'sleep 220; TZ=Asia/Tokyo date; curl -s https://example.com/api/status'
run_case pass "ループを伴わない単発の pgrep 確認" true 'pgrep -x Docker'
run_case pass "docker compose のテスト実行" true 'docker compose exec -T web php artisan test --compact'

if [[ "$failures" -gt 0 ]]; then
  printf '\nbash-background-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'bash-background-gate: %d 件すべて期待どおり\n' "$total"
