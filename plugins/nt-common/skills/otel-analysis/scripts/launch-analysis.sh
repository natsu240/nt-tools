#!/usr/bin/env bash
# Orca 管理外のターミナルでは ORCA_WORKTREE_ID 不在でそのままエラー終了する（意図した挙動、フォールバック無し）。

set -euo pipefail

NAME="$1"
readonly CLAUDE_SESSION_NAME_MAX=64
SUFFIX="-$$"
FULL_NAME="${NAME:0:$((CLAUDE_SESSION_NAME_MAX - ${#SUFFIX}))}${SUFFIX}"

if [[ -z "${CLAUDE_SKILL_DIR:-}" ]]; then
  echo "CLAUDE_SKILL_DIR が未設定です。呼び出し元でこの skill の Base directory を渡してから実行しろ。" >&2
  exit 1
fi

if [[ -z "${ORCA_WORKTREE_ID:-}" ]]; then
  echo "ORCA_WORKTREE_ID が未設定です。Orca 管理下のターミナルから実行しろ。" >&2
  exit 1
fi

# Orca のターミナルは対話 zsh なので、claude が関数・エイリアスに置き換えられていても実行ファイルを直接呼ぶ。
CREATE_JSON=$(orca terminal create --worktree "id:$ORCA_WORKTREE_ID" --title "$FULL_NAME" \
  --command "CLAUDE_SKILL_DIR='$CLAUDE_SKILL_DIR' OTEL_RESOURCE_ATTRIBUTES='launched_by=otel-analysis' command claude --agent nt-common:otel-analyst --name '$FULL_NAME' --model claude-sonnet-5 --effort medium" \
  --json)
TAB_HANDLE=$(printf '%s' "$CREATE_JSON" | jq -r '.result.terminal.handle')

if [[ -z "$TAB_HANDLE" || "$TAB_HANDLE" == "null" ]]; then
  echo "orca terminal create に失敗しました。出力:" >&2
  printf '%s\n' "$CREATE_JSON" >&2
  exit 1
fi

trap 'orca terminal close --terminal "$TAB_HANDLE" --tab --json >/dev/null 2>&1 || true' EXIT

orca terminal wait --terminal "$TAB_HANDLE" --for tui-idle --timeout-ms 60000 --json >/dev/null

trap - EXIT

echo "$TAB_HANDLE"
echo "$FULL_NAME"
