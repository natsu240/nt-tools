#!/usr/bin/env bash

set -uo pipefail

HOOKS="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)"

failures=0
total=0

judge() {
  local rc=$1 out=$2
  if [[ "$rc" -ne 0 ]]; then
    printf 'rc=%s' "$rc"
  elif grep -qE '"permissionDecision":[[:space:]]*"deny"' <<<"$out"; then
    printf 'deny'
  elif grep -qE '"permissionDecision":[[:space:]]*"ask"' <<<"$out"; then
    printf 'ask'
  else
    printf 'pass'
  fi
}

run_case() {
  local expected=$1 hook=$2 label=$3 payload=$4
  local out rc actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | bash "$HOOKS/$hook" 2>&1)"
  rc=$?
  actual="$(judge "$rc" "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-6s %s（%s）\n' "$expected" "$actual" "$label" "$hook"
    printf '    出力: %s\n' "$out"
    return
  fi
  if [[ "$expected" == "deny" ]] && ! jq -e '.systemMessage == .hookSpecificOutput.permissionDecisionReason and (.systemMessage | length > 0)' >/dev/null 2>&1 <<<"$out"; then
    failures=$((failures + 1))
    printf 'NG  理由が systemMessage に入っていない %s（%s）\n' "$label" "$hook"
    printf '    出力: %s\n' "$out"
  fi
}

write_payload() {
  jq -nc --arg f "$1" '{tool_name: "Write", tool_input: {file_path: $f, content: "x"}}'
}

# --- deny-fork-direct-launch.sh ---
run_case deny deny-fork-direct-launch.sh "fork の直接起動" \
  "$(jq -nc '{tool_name: "Agent", tool_input: {subagent_type: "fork"}}')"
run_case pass deny-fork-direct-launch.sh "別のサブエージェントを起動" \
  "$(jq -nc '{tool_name: "Agent", tool_input: {subagent_type: "nt-common:explorer"}}')"

# --- deny-temp-file-creation.sh ---
run_case deny deny-temp-file-creation.sh "tmp- で始まるファイル名" \
  "$(write_payload '/home/user/app/tmp-check.php')"
run_case deny deny-temp-file-creation.sh "アンダースコアで始まるファイル名" \
  "$(write_payload '/home/user/app/_W3LayoutCheckTest.php')"
run_case pass deny-temp-file-creation.sh "用途を表す正式な名前" \
  "$(write_payload '/home/user/app/LayoutValidator.php')"
run_case pass deny-temp-file-creation.sh "通常運用のドットファイル" \
  "$(write_payload '/home/user/app/.gitignore')"

if [[ "$failures" -gt 0 ]]; then
  printf '\ndeny-decision-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'deny-decision-gate: %d 件すべて期待どおり\n' "$total"
