#!/usr/bin/env bash
# Edit / Write / MultiEdit / 状態を変える Bash / commit・pr skill の起動時に効く PreToolUse hook。
# 計画に「決めたこと」表（未確定の行なし）と「確認テスト: 合格」「計画書レビュー: 合格」が揃っていなければ deny する。
#
# 計画が特定できなければ素通しする（「会話の出力画面に提示するだけ」の規模を巻き込まないため）。
# skill が起動済みかどうかは deny-plan-skill-gate.sh の担当であり、ここでは見ない。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-tool-target.sh
source "${BASH_SOURCE[0]%/*}/lib-tool-target.sh"
# shellcheck source=lib-plan-file-path.sh
source "${BASH_SOURCE[0]%/*}/lib-plan-file-path.sh"
# shellcheck source=lib-plan-lookup.sh
source "${BASH_SOURCE[0]%/*}/lib-plan-lookup.sh"

INPUT_JSON="$(cat)"

is_issue_body_write_only_command() {
  local stripped
  stripped="$(strip_quoted "$1")"
  grep -qE '[&|;`><]|\$\(' <<<"$stripped" && return 1
  [[ "$stripped" == *$'\n'* ]] && return 1
  grep -qE '^[[:space:]]*gh[[:space:]]+issue[[:space:]]+edit[[:space:]]' <<<"$stripped" || return 1
  grep -qE '[[:space:]]--body(-file)?([[:space:]]|=|$)' <<<"$stripped"
}

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"

CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
TARGET_DIR=""

case "$TOOL_NAME" in
  Bash)
    COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
    bash_command_in_scope "$COMMAND" || exit 0
    is_issue_body_write_only_command "$COMMAND" && exit 0
    [[ -n "$CWD" ]] && TARGET_DIR="$(effective_cwd "$COMMAND" "$CWD")"
    ;;
  Edit|Write|MultiEdit)
    FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
    is_scratch_path "$FILE_PATH" && exit 0
    is_plan_file_path "$FILE_PATH" && exit 0
    TARGET_DIR="$(nearest_existing_dir "$FILE_PATH")"
    ;;
  Skill)
    SKILL_NAME="$(jq -r '.tool_input.skill // empty' <<<"$INPUT_JSON")"
    grep -qE '^(nt-developer:)?(commit|pr)$' <<<"$SKILL_NAME" || exit 0
    is_scratch_path "$CWD" && exit 0
    TARGET_DIR="$CWD"
    ;;
  *)
    exit 0
    ;;
esac

[[ -n "$TARGET_DIR" ]] || exit 0

PLAN_BODY="$(lookup_plan_body "$TARGET_DIR")"
[[ -n "$PLAN_BODY" ]] || exit 0

if ! grep -qE '^#{2,4}[[:space:]]*決めたこと' <<<"$PLAN_BODY"; then
  REASON="🚫 計画に「決めたこと」節が無い。新しい節が無い古い計画にも例外は無い。plan skill の手順（先に調べる → 実装差が出る分岐を全部列挙する → 1問ずつ AskUserQuestion で確定する）をやり直し、「決めたこと」表を埋めてから再試行しろ。"
  emit_pretooluse_decision deny "$REASON"
  exit 0
fi

DECIDED_SECTION="$(awk '
  /^#{2,4}[[:space:]]*決めたこと/ { f=1; next }
  f && /^#{1,4}[[:space:]]/ { exit }
  f { print }
' <<<"$PLAN_BODY")"

UNRESOLVED=0
SEP_SEEN=0
while IFS= read -r line; do
  if [[ "$line" =~ ^\|[-:\ |]+\|$ ]]; then
    SEP_SEEN=1
    continue
  fi
  if [[ "$SEP_SEEN" -eq 1 && "$line" == \|*\|* ]]; then
    LAST_CELL="$(printf '%s' "$line" | sed -E 's/^\|//; s/\|[[:space:]]*$//' | awk -F'|' '{print $NF}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -z "$LAST_CELL" || "$LAST_CELL" == "未確定" ]] && UNRESOLVED=1
  fi
done <<<"$DECIDED_SECTION"

if [[ "$UNRESOLVED" -eq 1 ]]; then
  REASON="🚫 計画の「決めたこと」表に未確定の行が残っている。AskUserQuestion で1問ずつ確定させてから再試行しろ。"
  emit_pretooluse_decision deny "$REASON"
  exit 0
fi

if ! grep -qF '確認テスト: 合格' <<<"$PLAN_BODY"; then
  REASON="🚫 計画に「確認テスト: 合格」の記録が無い。plan skill の確認テスト手順（該当する観点だけを断定文にして1件ずつ AskUserQuestion で確認する）を行い、食い違いがゼロになったら「確認テスト: 合格（YYYY-MM-DD）」を計画に書いてから再試行しろ。"
  emit_pretooluse_decision deny "$REASON"
  exit 0
fi

if ! grep -qF '計画書レビュー: 合格' <<<"$PLAN_BODY"; then
  REASON="🚫 計画に「計画書レビュー: 合格」の記録が無い。Skill ツールで nt-developer:plan-review を起動し、計画を全文読み直してレビュー観点を全部当て、見つけた項目を直したうえで「計画書レビュー: 合格（YYYY-MM-DD）」を計画に書いてから再試行しろ。"
  emit_pretooluse_decision deny "$REASON"
  exit 0
fi

exit 0
