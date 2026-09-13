#!/usr/bin/env bash
# Bash の PostToolUse hook。実行できたコマンドのカテゴリ名だけ目印に追記する。
#
# PostToolUse はツールが成功したときだけ走り、失敗は PostToolUseFailure、PreToolUse の拒否ではどちらも発火しない。記録するだけで「成功した実行だけ数える」が自動的に成り立つ。
#
# **会話ログを見て数える方式に戻すな。** 拒否された試行の tool_result（is_error）が書き込まれる前に次の実行を試すと、その拒否が「成功した実行」として数えられる。
#
# 対象外のコマンドでも空のファイルを作る。判定側が「ファイルがある = この記録役が動いている環境」と判断するため。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
if [[ "$TOOL_NAME" != "Bash" || -z "$SESSION_ID" ]]; then
  exit 0
fi

state_dir="$HOME/.claude/hook-state"
mkdir -p "$state_dir" 2>/dev/null
log="$state_dir/${SESSION_ID}_git_commands.log"
touch "$log" 2>/dev/null

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# shellcheck source=lib-git-command-category.sh
source "${BASH_SOURCE[0]%/*}/lib-git-command-category.sh"

CATEGORY="$(git_command_category "$command")"
[[ -z "$CATEGORY" ]] && exit 0

printf '%s\n' "$CATEGORY" >>"$log" 2>/dev/null

exit 0
