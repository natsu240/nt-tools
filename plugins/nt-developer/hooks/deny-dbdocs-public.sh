#!/usr/bin/env bash
# Bash PreToolUse hook。
# dbdocs build を --private 無しで叩くと DB 設計書が公開されるため、--private が付いていない dbdocs build コマンドをブロックする。

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
[ -z "$command" ] && exit 0

if printf '%s' "$command" | grep -qE '(^|[[:space:]/;&|])dbdocs[[:space:]]+build\b' \
   && ! printf '%s' "$command" | grep -qE '\-\-private\b'; then
  reason="🚫 dbdocs build に --private が付いていない。DB設計書が公開されるコマンドパターンと一致する。正しい形: dbdocs build --project <workspace>/<name> --private"
  emit_pretooluse_decision deny "$reason"
fi

exit 0
