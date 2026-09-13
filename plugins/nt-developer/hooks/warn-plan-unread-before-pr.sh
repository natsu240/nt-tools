#!/usr/bin/env bash
# commit / pr 系 skill の PreToolUse hook。計画書（plans 配下の計画書か Issue の description）を作成したのにまだ読んでいなければ deny にする。
#
# 判定材料は会話ログと Read 履歴の記録の2つ。どちらも無い環境では判定できないので素通しする。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Skill" ]] && exit 0

SKILL_NAME="$(jq -r '.tool_input.skill // empty' <<<"$INPUT_JSON")"
grep -qE '^(nt-developer:)?(commit|pr|pr-followup|pr-comment)$' <<<"$SKILL_NAME" || exit 0

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
READS_LOG="$HOME/.claude/hook-state/${SESSION_ID}_reads.log"

has_transcript=0
[[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] && has_transcript=1
has_reads_log=0
[[ -n "$SESSION_ID" && -f "$READS_LOG" ]] && has_reads_log=1
[[ "$has_transcript" -eq 1 || "$has_reads_log" -eq 1 ]] || exit 0

if [[ "$has_reads_log" -eq 1 ]] && grep -qE '(^|/)plans/' "$READS_LOG" 2>/dev/null; then
  exit 0
fi

[[ "$has_transcript" -eq 1 ]] || exit 0

read_paths="$(
  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Read")
    | .input.file_path // empty
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true
)"
if grep -qE '(^|/)plans/' <<<"$read_paths"; then
  exit 0
fi

bash_commands="$(
  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | .input.command // empty
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true
)"
if grep -qE 'gh[[:space:]]+issue[[:space:]]+view' <<<"$bash_commands"; then
  exit 0
fi

plan_launched="$(
  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Skill")
    | .input.skill // empty
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true
)"
grep -qE '^(nt-developer:)?plan$' <<<"$plan_launched" || exit 0

write_paths="$(
  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and (.name == "Write" or .name == "Edit"))
    | .input.file_path // empty
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true
)"
plan_doc_created=0
grep -qE '(^|/)plans/' <<<"$write_paths" && plan_doc_created=1
grep -qE 'gh[[:space:]]+issue[[:space:]]+create' <<<"$bash_commands" && plan_doc_created=1
[[ "$plan_doc_created" -eq 1 ]] || exit 0

REASON="🚫 計画書（plans 配下の計画書または Issue の description）を作成したのにまだ読んでいない。${SKILL_NAME} に進む前に、対象の実装計画書または Issue の description を全文読め。計画を読まずにスコープを判断するな。"
emit_pretooluse_decision deny "$REASON"

exit 0
