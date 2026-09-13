#!/usr/bin/env bash
set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Read" ]] && exit 0

FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
[[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

# offset/limit が既に指定されているなら、対応済みとみなして何もしない
OFFSET="$(jq -r '.tool_input.offset // empty' <<<"$INPUT_JSON")"
LIMIT="$(jq -r '.tool_input.limit // empty' <<<"$INPUT_JSON")"
[[ -n "$OFFSET" || -n "$LIMIT" ]] && exit 0

SIZE="$(stat -c '%s' "$FILE_PATH" 2>/dev/null || stat -f '%z' "$FILE_PATH" 2>/dev/null || echo 0)"
THRESHOLD=$((256 * 1024))
[[ "$SIZE" -le "$THRESHOLD" ]] && exit 0

KB=$((SIZE / 1024))
REASON="$(jq -n -r --arg path "$FILE_PATH" --arg kb "$KB" '
  "🔍 " + $path + "（約" + $kb + "KB）は一括 Read の上限(256KB)を超えている可能性が高い。offset/limit を指定するか、grep -c 等で行数・該当箇所を先に絞り込め。"
')"
emit_pretooluse_decision allow "$REASON"
exit 0
