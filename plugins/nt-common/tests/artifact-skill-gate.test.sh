#!/usr/bin/env bash
# deny-artifact-skill.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-artifact-skill.sh"
[[ -f "$HOOK" ]] || { echo "deny-artifact-skill.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/hook-state"

EMPTY_TRANSCRIPT="$TMP_ROOT/empty.jsonl"
: >"$EMPTY_TRANSCRIPT"

TEMPLATES_TRANSCRIPT="$TMP_ROOT/templates.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "nt-common:artifact-templates"}}]}}' >"$TEMPLATES_TRANSCRIPT"

ARCH_TRANSCRIPT="$TMP_ROOT/arch.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "nt-common:artifact-architecture"}}]}}' >"$ARCH_TRANSCRIPT"

DESIGN_TRANSCRIPT="$TMP_ROOT/design.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "artifact-design"}}]}}' >"$DESIGN_TRANSCRIPT"

SLASH_TRANSCRIPT="$TMP_ROOT/slash.jsonl"
jq -cn '{type: "user", message: {role: "user", content: "<command-message>nt-common:artifact-templates</command-message>\n<command-name>/nt-common:artifact-templates</command-name>\n<command-args>一覧を作って</command-args>"}}' >"$SLASH_TRANSCRIPT"

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
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | HOME="$FAKE_HOME" bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-4s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 書き込み系の action ---
run_raw_case deny "action 未指定(publish) は未起動なら止める" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {file_path: "/repo/report.html"}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case deny "upload_asset も未起動なら止める" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {action: "upload_asset", url: "https://x", file_path: "/repo/a.png"}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case deny "artifact-design だけ起動していても止める" "$(jq -nc --arg t "$DESIGN_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {file_path: "/repo/report.html"}, session_id: "design-only", transcript_path: $t}')"

# --- 止めてはいけない例 ---
run_raw_case pass "artifact-templates 起動済み" "$(jq -nc --arg t "$TEMPLATES_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {file_path: "/repo/report.html"}, session_id: "ready", transcript_path: $t}')"
run_raw_case pass "artifact-architecture 起動済み" "$(jq -nc --arg t "$ARCH_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {file_path: "/repo/diagram.html"}, session_id: "arch-ready", transcript_path: $t}')"
run_raw_case pass "スラッシュコマンドでの起動でも通る" "$(jq -nc --arg t "$SLASH_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {file_path: "/repo/report.html"}, session_id: "slash-ready", transcript_path: $t}')"
run_raw_case pass "read は未起動でも通る" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {action: "read", url: "https://x"}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case pass "list は未起動でも通る" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {action: "list"}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case pass "comments は未起動でも通る" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {action: "comments", url: "https://x"}, session_id: "no-skill", transcript_path: $t}')"
run_raw_case pass "サブエージェントからの呼び出しは対象外" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Artifact", tool_input: {file_path: "/repo/report.html"}, session_id: "no-skill", transcript_path: $t, agent_id: "sub-1", agent_type: "explorer"}')"
run_raw_case pass "対象外ツール(Read)" "$(jq -nc --arg t "$EMPTY_TRANSCRIPT" '{tool_name: "Read", tool_input: {file_path: "/repo/a.md"}, session_id: "no-skill", transcript_path: $t}')"

if [[ "$failures" -gt 0 ]]; then
  printf '\nartifact-skill-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'artifact-skill-gate: %d 件すべて期待どおり\n' "$total"
