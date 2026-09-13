#!/usr/bin/env bash
# git commit に Co-Authored-By が含まれていたら block する PreToolUse hook。
# 運用ルール: Co-Authored-By を付けるな（CLAUDE.md / nt-tools README）。

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
[ -z "$command" ] && exit 0

# git commit が含まれない → 素通し
if ! printf '%s' "$command" | grep -qE '(^|[[:space:]/;&|])git[[:space:]]+commit'; then
  exit 0
fi

# Co-Authored-By / Co-Author 系を大文字小文字・ハイフン無し含めて検出
if printf '%s' "$command" | grep -qiE 'Co-?Authored-?By'; then
  reason=$(printf '%s\n' \
    "🚫 git commit に Co-Authored-By が含まれている。この環境の運用ルールで禁止。" \
    "   Co-Authored-By 行を外して再実行してください。" \
    "   今後 Claude Code 自体に付けさせたくない場合は、個人の ~/.claude/settings.json に以下を追加すると解決します:" \
    '   {"attribution": {"commit": "", "pr": "", "sessionUrl": false}}')
  jq -n --arg msg "$reason" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $msg
      },
      systemMessage: $msg
    }
  '
fi

exit 0
