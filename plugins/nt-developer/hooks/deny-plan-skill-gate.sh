#!/usr/bin/env bash
# Edit / Write / MultiEdit / 状態を変える Bash の PreToolUse hook。
# 担当する skill は plan / plan-review / implement / review / deploy-watch / pr-comment / pr-followup の7つで、そのセッションでどれも未起動なら deny する。ワークツリーの中では plan / plan-review を除いた5つだけを認める。
#
# 計画書を作るかどうかの判定は plan 側に置いてある。ここは起動だけを担保する。
# 条件（まとまった実装なら起動しろ 等）を文章で書くと、判定が起動前に行われるため、skill の本文を読んでいない状態で「これは小さいから不要」と自己判断できてしまう。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-called-skills.sh
source "${BASH_SOURCE[0]%/*}/lib-called-skills.sh"
# shellcheck source=lib-tool-target.sh
source "${BASH_SOURCE[0]%/*}/lib-tool-target.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
case "$TOOL_NAME" in
  Edit|Write|MultiEdit|Bash) ;;
  *) exit 0 ;;
esac

CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"

if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
  bash_command_in_scope "$COMMAND" || exit 0
  TARGET_DIR=""
  [[ -n "$CWD" ]] && TARGET_DIR="$(effective_cwd "$COMMAND" "$CWD")"
else
  # 一時ディレクトリ配下は対象外にする。使い捨ての調査スクリプト（集計器・構文チェッカ 等）に実装計画を要求する意味が無いうえ、長文のインライン実行は別の hook が「Write でファイル化しろ」と止めるため、そのファイル化まで deny すると退路が塞がる。
  FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
  is_scratch_path "$FILE_PATH" && exit 0
  TARGET_DIR="$(nearest_existing_dir "$FILE_PATH")"
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
CALLED_SKILLS="$(collect_called_skills "$SESSION_ID" "$TRANSCRIPT_PATH")"

IN_WORKTREE=false
if [[ -n "$TARGET_DIR" ]] && is_linked_worktree "$TARGET_DIR"; then
  IN_WORKTREE=true
fi

ALLOWED_SKILLS_RE='^(nt-developer:)?(plan|plan-review|implement|review|deploy-watch|pr-comment|pr-followup)$'
if [[ "$IN_WORKTREE" == true ]]; then
  ALLOWED_SKILLS_RE='^(nt-developer:)?(implement|review|deploy-watch|pr-comment|pr-followup)$'
  # gripe skill が作るワークツリー（`gripe-YYYYMMDD-HHMMSS` 名）は Issue 起票から実装までを1セッションで完結させる運用のため、plan も許可する。
  WORKTREE_ROOT="$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$WORKTREE_ROOT" && "$(basename "$WORKTREE_ROOT")" == gripe-* ]]; then
    ALLOWED_SKILLS_RE='^(nt-developer:)?(plan|plan-review|implement|review|deploy-watch|pr-comment|pr-followup)$'
  fi
  if [[ -n "$WORKTREE_ROOT" && "$(basename "$WORKTREE_ROOT")" == auto-review-* ]]; then
    exit 0
  fi
fi

# grep はパイプの終端に置くな。set -o pipefail 下では grep -q がマッチした瞬間に終了して上流が SIGPIPE で死に、その終了ステータスがパイプライン全体の結果になる。here-string で渡す。
if grep -qE "$ALLOWED_SKILLS_RE" <<<"$CALLED_SKILLS"; then
  exit 0
fi

if [[ "$IN_WORKTREE" == false ]]; then
  REASON="$(jq -n -r --arg tool "$TOOL_NAME" '
    "🚫 plan / implement / review / deploy-watch / pr-comment / pr-followup skill がどれも未起動のまま " + $tool + " を実行しようとしています。計画から始めるなら Skill ツールで nt-developer:plan を、承認済みの計画の実装の続きなら nt-developer:implement を、実装済みの差分のレビュー以降なら nt-developer:review を、マージ済みでデプロイ後の確認をするなら nt-developer:deploy-watch を、PR へのコメント／approve／変更依頼の投稿だけなら nt-developer:pr-comment を、既存 PR のレビュー指摘へ対応するなら nt-developer:pr-followup を起動してから再試行しろ。何を作るか（何も作らない / 会話の出力画面に提示するだけ / Issue か plans に書く）の判定は plan が持っている。"
  ')"
else
  REASON="$(jq -n -r --arg tool "$TOOL_NAME" '
    "🚫 ここはワークツリーの中で、実装以降の作業をする場所です。implement / review / deploy-watch / pr-comment / pr-followup skill がどれも未起動のまま " + $tool + " を実行しようとしています（plan だけでは通りません。計画セッションは本体のチェックアウトで回す運用です）。承認済みの計画の実装なら Skill ツールで nt-developer:implement を、実装済みの差分のレビュー以降なら nt-developer:review を、マージ済みでデプロイ後の確認をするなら nt-developer:deploy-watch を、PR へのコメント／approve／変更依頼の投稿だけなら nt-developer:pr-comment を、既存 PR のレビュー指摘へ対応するなら nt-developer:pr-followup を起動してから再試行しろ。"
  ')"
fi
emit_pretooluse_decision deny "$REASON"

exit 0
