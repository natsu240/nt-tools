#!/usr/bin/env bash
# Bash PreToolUse hook。git commit / gh pr create|edit|review / gh api の PR 投稿系を、対応する skill を起動せずに直接叩こうとしたら deny する（skill 起動1回につき1コマンド）。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# shellcheck source=lib-git-command-category.sh
source "${BASH_SOURCE[0]%/*}/lib-git-command-category.sh"
# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

CATEGORY="$(git_command_category "$command")"
[[ -z "$CATEGORY" ]] && exit 0

# bash 3.2 には mapfile が無いので read で詰める。
REQUIRED_SKILLS=()
while IFS= read -r s; do
  [[ -n "$s" ]] && REQUIRED_SKILLS+=("$s")
done < <(git_category_skills "$CATEGORY")
[[ "${#REQUIRED_SKILLS[@]}" -eq 0 ]] && exit 0

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
STATE_DIR="$HOME/.claude/hook-state"
CMD_LOG="$STATE_DIR/${SESSION_ID}_git_commands.log"
SKILL_LOG="$STATE_DIR/${SESSION_ID}_skills.log"

count_lines() {
  local pattern="$1" file="$2" n
  [[ -f "$file" ]] || { printf '0'; return; }
  n="$(grep -cxF -- "$pattern" "$file" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# 記録役が動いている環境（対象外のコマンドでも空ファイルが作られる）なら、目印ファイルの回数だけで判定する。会話ログは見ない。
if [[ -n "$SESSION_ID" && -f "$CMD_LOG" ]]; then
  skill_count=0
  for s in "${REQUIRED_SKILLS[@]}"; do
    skill_count=$((skill_count + $(count_lines "$s" "$SKILL_LOG")))
  done
  cmd_count="$(count_lines "$CATEGORY" "$CMD_LOG")"
  if [[ "$skill_count" -gt "$cmd_count" ]]; then
    exit 0
  fi
else
  TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
  if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
    exit 0
  fi

  CATEGORY_RE="$(git_category_consume_regex "$CATEGORY")"

  # この hook の deny・実行時エラーで終わった試行は「消費」に数えない。
  FAILED_TOOL_USE_IDS="$(
    jq -r '
      select(.type == "user")
      | .message.content[]?
      | select(.type == "tool_result")
      | select(.is_error == true)
      | .tool_use_id // empty
    ' "$TRANSCRIPT_PATH" 2>/dev/null || true
  )"

  authorized="false"
  skill_seen=0
  while IFS=' ' read -r kind tool_use_id b64; do
    value="$(printf '%s' "$b64" | base64 -d 2>/dev/null || printf '%s' "$b64" | base64 -D 2>/dev/null)"
    if [[ "$kind" == "skill" ]]; then
      for s in "${REQUIRED_SKILLS[@]}"; do
        if [[ "$value" == "$s" ]]; then
          authorized="true"
          skill_seen=$((skill_seen + 1))
          break
        fi
      done
    elif [[ "$kind" == "cmd" ]]; then
      if grep -qxF -- "$tool_use_id" <<<"$FAILED_TOOL_USE_IDS"; then
        continue
      fi
      if printf '%s' "$(strip_quoted "$value")" | grep -qE "$CATEGORY_RE"; then
        authorized="false"
      fi
    fi
  done < <(
    jq -r '
      select(.type == "assistant")
      | .message.content[]?
      | select(.type == "tool_use")
      | if .name == "Skill" then "skill - " + ((.input.skill // "") | @base64)
        elif .name == "Bash" then "cmd " + (.id // "-") + " " + ((.input.command // "") | @base64)
        else empty end
    ' "$TRANSCRIPT_PATH" 2>/dev/null
  )

  # 会話ログへの書き込みが hook の実行時点で間に合っておらず、直前の skill 起動が載っていないことがある。PostToolUse が残した記録のほうが起動回数が多いなら、その差分は「会話ログにまだ現れていない起動」なので認可する。
  # 使い切り式を壊さないよう、記録の有無ではなく回数の差で判定する。
  if [[ "$authorized" != "true" && -n "$SESSION_ID" && -f "$SKILL_LOG" ]]; then
    logged=0
    for s in "${REQUIRED_SKILLS[@]}"; do
      logged=$((logged + $(count_lines "$s" "$SKILL_LOG")))
    done
    if [[ "$logged" -gt "$skill_seen" ]]; then
      authorized="true"
    fi
  fi

  if [[ "$authorized" == "true" ]]; then
    exit 0
  fi
fi

MAIN_SKILL="${REQUIRED_SKILLS[1]}"
REASON="$(jq -n -r --arg cmd "$command" --arg skill "$MAIN_SKILL" '
  "🚫 " + $cmd + " を実行する前に、先に Skill ツールで " + $skill + " を起動してください。既に起動済みでも、直前に同カテゴリのコマンドを1回実行済みなら使用済みなので再度呼び直してください。"
')"
emit_pretooluse_decision deny "$REASON"
exit 0
