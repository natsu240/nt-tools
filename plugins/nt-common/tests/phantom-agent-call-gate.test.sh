#!/usr/bin/env bash

set -uo pipefail

HOOKS_DIR="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)"
GATE_HOOK="$HOOKS_DIR/deny-phantom-agent-call.sh"
[[ -f "$GATE_HOOK" ]] || { echo "hook が見つかりません: $GATE_HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PHANTOM_TEXT='Agent({
  subagent_type: "fork",
  name: "read-plan-file",
  prompt: "計画書を読んで要約して"
})

続けて実装に入ります。'

QUOTED_TEXT='`Agent({subagent_type: "fork", name: "read-plan-file"})` を起動したと書いてしまいました。'

FENCED_TEXT='禁止されている呼び出しの例はこれです。

```
Agent({
  subagent_type: "fork"
})
```

以上。'

# 引数: $1=assistant の本文 $2=同じターンでの Agent 実呼び出しの有無（call/none）
make_transcript() {
  local text=$1 real_call=$2 path="$TMP_ROOT/transcript-$3.jsonl"
  {
    jq -cn '{type: "user", message: {content: "計画書を読んで"}}'
    jq -cn --arg t "$text" '{type: "assistant", message: {content: [{type: "text", text: $t}]}}'
    if [[ "$real_call" == "call" ]]; then
      jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Agent", input: {subagent_type: "nt-common:explorer"}}]}}'
    fi
  } >"$path"
  printf '%s' "$path"
}

EMPTY_TRANSCRIPT="$TMP_ROOT/empty.jsonl"
: >"$EMPTY_TRANSCRIPT"

failures=0
total=0

# 引数: $1=transcript_path $2=last_assistant_message $3=stop_hook_active $4=agent_type $5=agent_id
stop_payload() {
  jq -cn --arg t "$1" --arg m "$2" --argjson a "$3" --arg at "${4:-worker}" --arg aid "${5:-}" \
    '{hook_event_name: "Stop", transcript_path: $t, last_assistant_message: $m, stop_hook_active: $a, agent_type: $at, agent_id: $aid}'
}

run_gate() {
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | bash "$GATE_HOOK" 2>&1)"
  if [[ -z "$out" ]]; then
    actual=pass
  elif jq -e '.decision == "block" and (.reason | length > 0)' >/dev/null 2>&1 <<<"$out"; then
    actual=block
  else
    actual=other
  fi
  [[ "$actual" == "$expected" ]] && return
  failures=$((failures + 1))
  printf 'NG  期待=%-5s 実際=%-5s %s\n' "$expected" "$actual" "$label"
  printf '    出力: %s\n' "$out"
}

# --- 止める例 ---
run_gate block "本文へ印字しただけで実行していない" \
  "$(stop_payload "$(make_transcript "$PHANTOM_TEXT" none phantom)" "" false)"
run_gate block "会話ログに未反映で last_assistant_message にだけ現れる" \
  "$(stop_payload "$EMPTY_TRANSCRIPT" "$PHANTOM_TEXT" false)"

# --- 止めてはいけない例 ---
run_gate pass "インラインコードとして引用しただけ" \
  "$(stop_payload "$(make_transcript "$QUOTED_TEXT" none quoted)" "" false)"
run_gate pass "囲みコードブロックの中で引用しただけ" \
  "$(stop_payload "$(make_transcript "$FENCED_TEXT" none fenced)" "" false)"
run_gate pass "印字はあるが同じターンで実際に Agent を呼んでいる" \
  "$(stop_payload "$(make_transcript "$PHANTOM_TEXT" call real)" "" false)"
run_gate pass "既に一度止めて会話を続けさせている最中" \
  "$(stop_payload "$(make_transcript "$PHANTOM_TEXT" none active)" "" true)"
run_gate pass "サブエージェントのターン" \
  "$(stop_payload "$(make_transcript "$PHANTOM_TEXT" none subagent)" "" false nt-common:explorer explorer-agent-1)"
run_gate pass "印字が無い普通のターン" \
  "$(stop_payload "$(make_transcript "計画書を読みました。要点は3つです。" none plain)" "" false)"
run_gate pass "会話ログも last_assistant_message も空" \
  "$(stop_payload "$EMPTY_TRANSCRIPT" "" false)"

if [[ "$failures" -gt 0 ]]; then
  printf '\nphantom-agent-call-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'phantom-agent-call-gate: %d 件すべて期待どおり\n' "$total"
