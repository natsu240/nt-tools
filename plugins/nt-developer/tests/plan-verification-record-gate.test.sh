#!/usr/bin/env bash

set -uo pipefail

HOOKS_DIR="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)"
GATE_HOOK="$HOOKS_DIR/deny-plan-verification-record.sh"
[[ -f "$GATE_HOOK" ]] || { echo "hook が見つかりません: $GATE_HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/hook-state"
SESSION_ID="session-test"
ASK_LOG="$FAKE_HOME/.claude/hook-state/${SESSION_ID}_ask-questions.log"

# gh issue view を呼ばせないための差し替え。書き込み前の description は GH_BODY_FILE の中身で決める。
mkdir -p "$TMP_ROOT/bin"
GH_BODY_FILE="$TMP_ROOT/gh-body.md"
: >"$GH_BODY_FILE"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
  cat "$GH_BODY_FILE"
  exit 0
fi
exit 1
STUB
chmod +x "$TMP_ROOT/bin/gh"

ASSERTION_A='マージした時点で本番に副作用が出る: この変更をマージすると全セッションの plan 経路に新しい deny が1つ増える。'
ASSERTION_B='同じ原因を抱えているのに今回の対象から外した箇所がある: 決めたことの分岐確定には検査を足さない。'

plan_body() {
  printf '%s\n' \
    '## 確認テスト' \
    '' \
    '該当した観点:' \
    '' \
    "- $ASSERTION_A — 確認済み（2026-09-09）" \
    "- $ASSERTION_B — 確認済み（2026-09-09）" \
    '' \
    '該当なしと判定した観点:' \
    '' \
    '- マージの前後に人が手でやる作業があり、順序を間違えると壊れる: 手作業が無い。' \
    '' \
    '確認テスト: 合格（2026-09-09）'
}

plan_body_without_applicable() {
  printf '%s\n' \
    '## 確認テスト' \
    '' \
    '該当した観点:' \
    '' \
    '該当なしと判定した観点:' \
    '' \
    '- マージした時点で本番に副作用が出る: 何も動かさない。' \
    '' \
    '確認テスト: 合格（2026-09-09）'
}

ASSERTION_C='マージした時点で本番に副作用が出る: マージすると artisan の `token:issue` が本番から消える。'

plan_body_with_code_format() {
  printf '%s\n' \
    '## 確認テスト' \
    '' \
    '該当した観点:' \
    '' \
    "- $ASSERTION_C — 確認済み（2026-09-10）" \
    '' \
    '該当なしと判定した観点:' \
    '' \
    '- マージの前後に人が手でやる作業があり、順序を間違えると壊れる: 手作業が無い。' \
    '' \
    '確認テスト: 合格（2026-09-10）'
}

plan_body_mentioning_header_in_prose() {
  printf '%s\n' \
    '## 確認テスト' \
    '' \
    '該当した観点:' \
    '' \
    '（なし）' \
    '' \
    '該当なしと判定した観点:' \
    '' \
    '- マージした時点で本番に副作用が出る: 何も動かさない。' \
    '' \
    '確認テスト: 合格（2026-09-10）' \
    '' \
    '## 現状' \
    '' \
    'hook は計画本文の該当した観点に並ぶ断定文だけを突き合わせる。' \
    '' \
    '- `lib-ask-questions.sh` の正規化処理は装飾記号を落とさない。' \
    '- 一覧の範囲判定は見出し行を見ていない。'
}

plan_body_only_prose_header() {
  printf '%s\n' \
    '## 現状' \
    '' \
    'hook は計画本文の該当した観点に並ぶ断定文だけを突き合わせる。' \
    '' \
    '確認テスト: 合格（2026-09-10）'
}

write_ask_log() {
  : >"$ASK_LOG"
  local question
  for question in "$@"; do
    printf '%s\n' "$question" >>"$ASK_LOG"
  done
}

assertion_only() {
  printf '%s' "${1#*: }"
}

failures=0
total=0

classify_gate() {
  if [[ -z "$1" ]]; then
    echo pass
  elif grep -q '"permissionDecision": "deny"' <<<"$1"; then
    echo deny
  else
    echo other
  fi
}

run_gate() {
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | HOME="$FAKE_HOME" PATH="$TMP_ROOT/bin:$PATH" GH_BODY_FILE="$GH_BODY_FILE" bash "$GATE_HOOK" 2>&1)"
  actual="$(classify_gate "$out")"
  [[ "$actual" == "$expected" ]] || { failures=$((failures + 1)); printf 'NG  期待=%-6s 実際=%-6s %s\n出力: %s\n' "$expected" "$actual" "$label" "$out"; }
}

bash_payload() {
  local command=$1
  jq -cn --arg command "$command" --arg session "$SESSION_ID" \
    '{tool_name: "Bash", tool_input: {command: $command}, session_id: $session}'
}

bash_payload_with_transcript() {
  local command=$1 transcript=$2
  jq -cn --arg command "$command" --arg session "$SESSION_ID" --arg transcript "$transcript" \
    '{tool_name: "Bash", tool_input: {command: $command}, session_id: $session, transcript_path: $transcript}'
}

write_payload() {
  local path=$1 content=$2
  jq -cn --arg path "$path" --arg content "$content" --arg session "$SESSION_ID" \
    '{tool_name: "Write", tool_input: {file_path: $path, content: $content}, session_id: $session}'
}

edit_payload() {
  local path=$1 new_string=$2
  jq -cn --arg path "$path" --arg new "$new_string" --arg session "$SESSION_ID" \
    '{tool_name: "Edit", tool_input: {file_path: $path, new_string: $new}, session_id: $session}'
}

BODY_FILE="$TMP_ROOT/issue-body.md"
plan_body >"$BODY_FILE"
PLANS_PATH="$TMP_ROOT/repo/plans/進行中/other/計画.md"
mkdir -p "${PLANS_PATH%/*}"

# --- 提示の記録が無い → 拒否 ---
write_ask_log
run_gate deny "提示の記録が無いまま description を書き込む" "$(bash_payload "gh issue edit 753 --body-file $BODY_FILE")"
run_gate deny "提示の記録が無いまま plans 配下へ書き込む" "$(write_payload "$PLANS_PATH" "$(plan_body)")"

# --- 該当した断定文すべてに対応する提示がある → 素通し ---
write_ask_log "$(assertion_only "$ASSERTION_A")" "$(assertion_only "$ASSERTION_B")"
run_gate pass "断定文すべてを提示済みの description 書き込み" "$(bash_payload "gh issue edit 753 --body-file $BODY_FILE")"
run_gate pass "断定文すべてを提示済みの plans 配下への書き込み" "$(write_payload "$PLANS_PATH" "$(plan_body)")"

# --- 一部しか提示していない → 拒否 ---
write_ask_log "$(assertion_only "$ASSERTION_A")"
run_gate deny "2件のうち1件しか提示していない" "$(bash_payload "gh issue edit 753 --body-file $BODY_FILE")"

# --- 無関係な質問で件数だけ埋める → 拒否 ---
write_ask_log "実装計画の書き込み先はどちらにするか。" "hook の判定の仕方はどちらにするか。"
run_gate deny "無関係な質問を必要件数ぶん投げただけ" "$(bash_payload "gh issue edit 753 --body-file $BODY_FILE")"

# --- 空白と改行だけが違う質問文 → 素通し ---
write_ask_log "$(assertion_only "$ASSERTION_A")  " "  $(assertion_only "$ASSERTION_B")"
run_gate pass "空白だけが違う質問文" "$(bash_payload "gh issue edit 753 --body-file $BODY_FILE")"

# --- 記録が無く会話ログにだけ提示が残っている → 素通し ---
write_ask_log
TRANSCRIPT="$TMP_ROOT/transcript.jsonl"
: >"$TRANSCRIPT"
for assertion in "$ASSERTION_A" "$ASSERTION_B"; do
  jq -cn --arg question "$(assertion_only "$assertion")" \
    '{type: "assistant", message: {content: [{type: "tool_use", name: "AskUserQuestion", input: {questions: [{question: $question}]}}]}}' \
    >>"$TRANSCRIPT"
done
run_gate pass "会話ログにだけ提示が残っている" "$(bash_payload_with_transcript "gh issue edit 753 --body-file $BODY_FILE" "$TRANSCRIPT")"

# --- 断定文のコード書式を外して提示した → 素通し ---
CODE_FORMAT_BODY_FILE="$TMP_ROOT/issue-body-code-format.md"
plan_body_with_code_format >"$CODE_FORMAT_BODY_FILE"
write_ask_log "$(printf '%s' "$(assertion_only "$ASSERTION_C")" | tr -d '`')"
run_gate pass "断定文のコード書式を外した質問文で提示済み" "$(bash_payload "gh issue edit 753 --body-file $CODE_FORMAT_BODY_FILE")"

# --- 見出し名と同じ語を別の節の文中で使った計画 → 素通し ---
write_ask_log
run_gate pass "別の節の文中で見出し名と同じ語を使った計画" "$(write_payload "$PLANS_PATH" "$(plan_body_mentioning_header_in_prose)")"

# --- 見出しが無く文中の言及だけ → 拒否 ---
run_gate deny "見出しが無く文中の言及だけで合格を書く" "$(write_payload "$PLANS_PATH" "$(plan_body_only_prose_header)")"

# --- 該当した観点が0件 → 素通し ---
write_ask_log
run_gate pass "該当した観点が0件の計画" "$(write_payload "$PLANS_PATH" "$(plan_body_without_applicable)")"

# --- 「該当した観点」を含まない書き込み → 拒否 ---
run_gate deny "合格の1行だけを足す書き込み" "$(edit_payload "$PLANS_PATH" '確認テスト: 合格（2026-09-09）')"

# --- 書き込み前から同じ断定文と合格の記録がある → 素通し（実装・レビューの各セッション） ---
plan_body >"$GH_BODY_FILE"
run_gate pass "提示済みの計画をチェックボックス更新のために書き直す" "$(bash_payload "gh issue edit 753 --body-file $BODY_FILE")"
plan_body >"$PLANS_PATH"
run_gate pass "提示済みの plans 配下の計画を書き直す" "$(write_payload "$PLANS_PATH" "$(plan_body)")"
run_gate pass "提示済みの plans 配下の計画へ合格の1行だけを足す" "$(edit_payload "$PLANS_PATH" '確認テスト: 合格（2026-09-09）')"
: >"$GH_BODY_FILE"
rm -f "$PLANS_PATH"

# --- 計画の書き込みではない操作 → 素通し ---
run_gate pass "確認テストを含まない description の書き込み" "$(bash_payload "gh issue edit 753 --body '実装ステップだけの計画'")"
run_gate pass "label だけを足す gh issue edit" "$(bash_payload 'gh issue edit 753 --add-label gripe')"
run_gate pass "通常のコミット" "$(bash_payload 'git commit -m plan')"
run_gate pass "plans 配下でないファイルへ合格の文字列を書く" "$(write_payload "$TMP_ROOT/repo/plugins/nt-developer/skills/plan/SKILL.md" "$(plan_body)")"

if [[ "$failures" -gt 0 ]]; then
  printf '\nplan-verification-record-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'plan-verification-record-gate: %d 件すべて期待どおり\n' "$total"
