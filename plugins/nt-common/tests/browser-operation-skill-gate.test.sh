#!/usr/bin/env bash
# deny-browser-operation-skill.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-browser-operation-skill.sh"
[[ -f "$HOOK" ]] || { echo "deny-browser-operation-skill.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/hook-state"

EMPTY_TRANSCRIPT="$TMP_ROOT/empty.jsonl"
: >"$EMPTY_TRANSCRIPT"

CALLED_TRANSCRIPT="$TMP_ROOT/called.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "nt-common:browser-operation"}}]}}' >"$CALLED_TRANSCRIPT"

ARCH_TRANSCRIPT="$TMP_ROOT/arch.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "nt-common:artifact-architecture"}}]}}' >"$ARCH_TRANSCRIPT"

SLASH_TRANSCRIPT="$TMP_ROOT/slash.jsonl"
jq -cn '{type: "user", message: {role: "user", content: "<command-message>nt-common:artifact-architecture</command-message>\n<command-name>/nt-common:artifact-architecture</command-name>\n<command-args>インフラ構成図を作って</command-args>"}}' >"$SLASH_TRANSCRIPT"

QUOTED_TRANSCRIPT="$TMP_ROOT/quoted.jsonl"
jq -cn '{type: "user", message: {role: "user", content: "hook が <command-name>/nt-common:artifact-architecture</command-name> を見落とす件"}}' >"$QUOTED_TRANSCRIPT"

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
  local expected=$1 label=$2 payload=$3 subprocess=${4:-}
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | HOME="$FAKE_HOME" NT_BROWSER_OPERATION_SUBPROCESS="$subprocess" bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-4s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

bash_payload() {
  local command=$1 transcript=$2 session=${3:-no-skill}
  jq -nc --arg c "$command" --arg t "$transcript" --arg s "$session" '{tool_name: "Bash", tool_input: {command: $c}, session_id: $s, transcript_path: $t}'
}

# --- orca のブラウザ操作コマンド ---
run_raw_case deny "orca goto 未起動" "$(bash_payload 'orca goto --url https://example.com --json' "$EMPTY_TRANSCRIPT")"
run_raw_case pass "orca goto は起動済みなら通る" "$(bash_payload 'orca goto --url https://example.com --json' "$CALLED_TRANSCRIPT" ready)"
run_raw_case deny "orca snapshot 未起動" "$(bash_payload 'orca snapshot --json' "$EMPTY_TRANSCRIPT")"
run_raw_case deny "orca click 未起動" "$(bash_payload 'orca click --element e3 --json' "$EMPTY_TRANSCRIPT")"
run_raw_case deny "パイプの後段の orca eval も見る" "$(bash_payload 'cat x.js | orca eval --expression "1+1" --json' "$EMPTY_TRANSCRIPT")"
run_raw_case deny "&& の後段の orca tab も見る" "$(bash_payload 'echo start && orca tab list --json' "$EMPTY_TRANSCRIPT")"
run_raw_case deny "改行で続く2行目の orca goto も見る" "$(bash_payload 'echo start
orca goto --url https://example.com --json' "$EMPTY_TRANSCRIPT")"
run_raw_case pass "orca goto は artifact-architecture 起動済みなら通る" "$(bash_payload 'orca goto --url file:///tmp/a.html --json' "$ARCH_TRANSCRIPT" arch-ready)"
run_raw_case pass "スラッシュコマンドでの artifact-architecture 起動でも通る" "$(bash_payload 'orca eval --expression "1" --json' "$SLASH_TRANSCRIPT" slash-ready)"
run_raw_case deny "会話本文に <command-name> と書いただけでは通らない" "$(bash_payload 'orca goto --url https://example.com --json' "$QUOTED_TRANSCRIPT" quoted-only)"

# --- 止めてはいけない orca のコマンド ---
run_raw_case pass "orca terminal は対象外" "$(bash_payload 'orca terminal create --title x --json' "$EMPTY_TRANSCRIPT")"
run_raw_case pass "orca worktree は対象外" "$(bash_payload 'orca worktree create --name issue-1 --json' "$EMPTY_TRANSCRIPT")"
run_raw_case pass "orca open は対象外" "$(bash_payload 'orca open' "$EMPTY_TRANSCRIPT")"
run_raw_case pass "クォートの中の orca goto は実行されない" "$(bash_payload "grep 'orca goto' README.md" "$EMPTY_TRANSCRIPT")"
run_raw_case pass "サブコマンド名と同じ語が別コマンドに出るだけ" "$(bash_payload 'git tab list' "$EMPTY_TRANSCRIPT")"
run_raw_case pass "orca 以外のコマンドの引数に出るだけ" "$(bash_payload 'echo orcagoto' "$EMPTY_TRANSCRIPT")"

# --- Agent(subagent_type: nt-common:browser-operator) ---
run_raw_case deny "Agent browser-operator 未起動" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Agent", tool_input: {subagent_type: "nt-common:browser-operator"}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case pass "Agent browser-operator は起動済みなら通る" "$(jq -nc --arg t "$CALLED_TRANSCRIPT" '{tool_name: "Agent", tool_input: {subagent_type: "nt-common:browser-operator"}, session_id: "ready", transcript_path: $t}')"
run_raw_case pass "Agent の他サブエージェントは対象外" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Agent", tool_input: {subagent_type: "general-purpose"}, session_id: "no-skill", transcript_path: $t}')"

# --- サブエージェント自身の呼び出しは対象外 ---
run_raw_case pass "nt-common:browser-operator 自身の呼び出しは対象外" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Bash", tool_input: {command: "orca goto --url https://example.com --json"}, session_id: "no-skill", transcript_path: $t, agent_type: "nt-common:browser-operator"}')"

# --- 別タブ起動（launch-browser-operator.sh 経由）は対象外 ---
run_raw_case pass "NT_BROWSER_OPERATION_SUBPROCESS 付きは skill 未起動でも通る" "$(bash_payload 'orca goto --url https://example.com --json' "$EMPTY_TRANSCRIPT")" 1
run_raw_case deny "NT_BROWSER_OPERATION_SUBPROCESS が空なら通らない" "$(bash_payload 'orca goto --url https://example.com --json' "$EMPTY_TRANSCRIPT")" ""

# --- 対象外のツール ---
run_raw_case pass "対象外ツール(Read)" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Read", tool_input: {file_path: "/repo/a.md"}, session_id: "no-skill", transcript_path: $t}')"

if [[ "$failures" -gt 0 ]]; then
  printf '\nbrowser-operation-skill-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'browser-operation-skill-gate: %d 件すべて期待どおり\n' "$total"
