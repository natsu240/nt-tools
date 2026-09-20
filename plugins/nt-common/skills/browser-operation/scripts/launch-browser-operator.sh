#!/usr/bin/env bash
# Orca 管理下の別タブに browser-operator agent の対話 claude を立て、タブの識別子と確定したセッション名を返す。
# Orca 管理外のターミナルでは別タブを立てる手段が無いため、ORCA_WORKTREE_ID 不在ならフォールバックせずエラー終了する。

set -euo pipefail

NAME="$1"
readonly CLAUDE_SESSION_NAME_MAX=64
SUFFIX="-$$"
FULL_NAME="${NAME:0:$((CLAUDE_SESSION_NAME_MAX - ${#SUFFIX}))}${SUFFIX}"

if [[ -z "${ORCA_WORKTREE_ID:-}" ]]; then
  echo "ORCA_WORKTREE_ID が未設定です。Orca 管理下のターミナルから実行しろ。" >&2
  exit 1
fi

# 別タブ側の agent は Skill ツールを持たず browser-operation skill を起動できないため、NT_BROWSER_OPERATION_SUBPROCESS を見て deny-browser-operation-skill.sh に素通しさせる。
# Orca のターミナルは対話シェルなので、claude が関数・エイリアスに置き換えられていても実行ファイルを直接呼ぶ。
CREATE_JSON=$(orca terminal create --worktree "id:$ORCA_WORKTREE_ID" --title "$FULL_NAME" \
  --command "NT_BROWSER_OPERATION_SUBPROCESS=1 OTEL_RESOURCE_ATTRIBUTES='launched_by=browser-operation' command claude --agent nt-common:browser-operator --name '$FULL_NAME' --model claude-sonnet-5 --effort medium" \
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
