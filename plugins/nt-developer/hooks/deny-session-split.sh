#!/usr/bin/env bash
# Skill の PreToolUse hook。同じセッションで計画→実装、実装→レビューへ続けて進むのを deny する。
#
# 計画が特定できないときは素通しする（計画を書かない規模の作業を巻き込まないため）。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-called-skills.sh
source "${BASH_SOURCE[0]%/*}/lib-called-skills.sh"
# shellcheck source=lib-tool-target.sh
source "${BASH_SOURCE[0]%/*}/lib-tool-target.sh"
# shellcheck source=lib-plan-lookup.sh
source "${BASH_SOURCE[0]%/*}/lib-plan-lookup.sh"

# 一気通貫で進めるリポジトリは project_notes/automation.md にこのマーカー行を置いて申告する。無ければ止める側に倒れる。
EXEMPT_MARKER_RE='^[[:space:]]*claude-session-split:[[:space:]]*skip[[:space:]]*$'

# project_notes/ は本体にしか置かれないため、共通の .git を持つ本体のディレクトリを見る。
is_exempt_repo() {
  local dir="$1" common notes
  [[ -n "$dir" ]] || return 1
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  notes="$(dirname "$common")/project_notes/automation.md"
  [[ -f "$notes" ]] || return 1
  grep -qE "$EXEMPT_MARKER_RE" "$notes"
}

# gripe / auto-review のワークツリーは無人の Claude が最後まで進むため、途中でセッションを分けると誰も続きをやらない。
is_exempt_worktree() {
  local dir="$1" root
  [[ -n "$dir" ]] || return 1
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  case "$(basename "$root")" in
    gripe-*|auto-review-*) return 0 ;;
    *) return 1 ;;
  esac
}

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" == "Skill" ]] || exit 0

SKILL_NAME="$(jq -r '.tool_input.skill // empty' <<<"$INPUT_JSON")"
case "$SKILL_NAME" in
  implement|nt-developer:implement)
    PREV_RE='^(nt-developer:)?plan$'
    PREV_LABEL="計画"
    NEXT_LABEL="実装"
    NEXT_COMMAND="/nt-developer:implement"
    ;;
  review|nt-developer:review)
    PREV_RE='^(nt-developer:)?implement$'
    PREV_LABEL="実装"
    NEXT_LABEL="レビュー"
    NEXT_COMMAND="/nt-developer:review"
    ;;
  *)
    exit 0
    ;;
esac

CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
is_scratch_path "$CWD" && exit 0

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
CALLED_SKILLS="$(collect_called_skills "$SESSION_ID" "$TRANSCRIPT_PATH")"

grep -qE "$PREV_RE" <<<"$CALLED_SKILLS" || exit 0

is_exempt_worktree "$CWD" && exit 0
is_exempt_repo "$CWD" && exit 0

PLAN_BODY="$(lookup_plan_body "$CWD")"
[[ -n "$PLAN_BODY" ]] || exit 0

REASON="$(jq -n -r --arg prev "$PREV_LABEL" --arg next "$NEXT_LABEL" --arg command "$NEXT_COMMAND" '
  "🚫 このセッションでは既に" + $prev + "セッションを回している。同じセッションで続けて" + $next + "へ進むな（" + $prev + "した本人の会話に判断が引きずられたまま次の工程へ入ると、同じ思い込みを見逃す）。今のセッションは計画への書き戻しまでで終わらせ、新しいセッションを開いて " + $command + " を起動しろ。対象リポジトリが一気通貫の運用なら、本体のチェックアウトの project_notes/automation.md に claude-session-split: skip の1行を置いて申告しろ。"
')"
emit_pretooluse_decision deny "$REASON"

exit 0
