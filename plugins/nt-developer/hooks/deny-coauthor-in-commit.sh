#!/usr/bin/env bash
# git commit に Co-Authored-By が含まれていたら block する PreToolUse hook。
# 運用ルール: Co-Authored-By を付けるな（CLAUDE.md / nt-tools README）。

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-body-file-content.sh
source "${BASH_SOURCE[0]%/*}/lib-body-file-content.sh"

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
[ -z "$command" ] && exit 0

# git commit が含まれない → 素通し
if ! printf '%s' "$command" | grep -qE '(^|[[:space:]/;&|])git[[:space:]]+commit'; then
  exit 0
fi

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
haystack=$(command_with_body_files "$command" "$cwd")

# Co-Authored-By / Co-Author 系を大文字小文字・ハイフン無し含めて検出
if grep -qiE 'Co-?Authored-?By' <<<"$haystack"; then
  reason=$(printf '%s\n' \
    "🚫 git commit に Co-Authored-By が含まれている。この環境の運用ルールで禁止。" \
    "   Co-Authored-By 行を外して再実行してください。" \
    "   今後 Claude Code 自体に付けさせたくない場合は、個人の ~/.claude/settings.json に以下を追加すると解決します:" \
    '   {"attribution": {"commit": "", "pr": "", "sessionUrl": false}}')
  emit_pretooluse_decision deny "$reason"
fi

exit 0
